!! Copyright (C) 2008 X. Andrade
!!
!! This program is free software; you can redistribute it and/or modify
!! it under the terms of the GNU General Public License as published by
!! the Free Software Foundation; either version 2, or (at your option)
!! any later version.
!!
!! This program is distributed in the hope that it will be useful,
!! but WITHOUT ANY WARRANTY; without even the implied warranty of
!! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!! GNU General Public License for more details.
!!
!! You should have received a copy of the GNU General Public License
!! along with this program; if not, write to the Free Software
!! Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
!! 02110-1301, USA.
!!

#include "global.h"

module current_oct_m
  use batch_oct_m
  use batch_ops_oct_m
  use boundaries_oct_m
  use comm_oct_m
  use derivatives_oct_m
  use geometry_oct_m
  use global_oct_m
  use hamiltonian_oct_m
  use hamiltonian_base_oct_m
  use lda_u_oct_m
  use mesh_oct_m
  use mesh_function_oct_m
  use messages_oct_m
  use mpi_oct_m
  use parser_oct_m
  use profiling_oct_m
  use projector_oct_m
  use scissor_oct_m
  use simul_box_oct_m
  use states_oct_m
  use states_dim_oct_m
  use symmetrizer_oct_m
  use varinfo_oct_m

  implicit none

  private

  type current_t
    integer :: method
  end type current_t
    

  public ::                               &
    current_t,                            &
    current_init,                         &
    current_end,                          &
    current_calculate,                    &
    current_heat_calculate,               &
    current_calculate_mel 

  integer, parameter, public ::           &
    CURRENT_GRADIENT           = 1,       &
    CURRENT_GRADIENT_CORR      = 2,       &
    CURRENT_HAMILTONIAN        = 3,       &
    CURRENT_FAST               = 4

contains

  subroutine current_init(this, sb)
    type(current_t), intent(out)   :: this
    type(simul_box_t), intent(in)  :: sb

    PUSH_SUB(current_init)

    !%Variable CurrentDensity
    !%Default gradient_corrected
    !%Type integer
    !%Section Hamiltonian
    !%Description
    !% This variable selects the method used to
    !% calculate the current density. For the moment this variable is
    !% for development purposes and users should not need to use
    !% it.
    !%Option gradient 1
    !% The calculation of current is done using the gradient operator. (Experimental)
    !%Option gradient_corrected 2
    !% The calculation of current is done using the gradient operator
    !% with additional corrections for the total current from non-local operators.
    !%Option hamiltonian 3
    !% The current density is obtained from the commutator of the
    !% Hamiltonian with the position operator. (Experimental)
    !%Option gradient_corrected_fast 4
    !% More efficient version of the gradient_corrected calculation of the current. (Experimental)
    !%End

    call parse_variable('CurrentDensity', CURRENT_GRADIENT_CORR, this%method)
    if(.not.varinfo_valid_option('CurrentDensity', this%method)) call messages_input_error('CurrentDensity')
    if(this%method /= CURRENT_GRADIENT_CORR) then
      call messages_experimental("CurrentDensity /= gradient_corrected")
    end if
    !The call to individual derivatives_perfom routines returns the derivatives along
    !the primitive axis in case of non-orthogonal cells, whereas the code expects derivatives
    !along the Cartesian axis.
    if(this%method == CURRENT_FAST .and. sb%nonorthogonal ) then
      call messages_not_implemented("CurrentDensity = fast with non-orthogonal cells")
    end if
    
    POP_SUB(current_init)
  end subroutine current_init

  ! ---------------------------------------------------------

  subroutine current_end(this)
    type(current_t), intent(inout) :: this

    PUSH_SUB(current_end)


    POP_SUB(current_end)
  end subroutine current_end

  ! ---------------------------------------------------------
  subroutine current_calculate(this, der, hm, geo, st, current, current_kpt)
    type(current_t),      intent(in)    :: this
    type(derivatives_t),  intent(inout) :: der
    type(hamiltonian_t),  intent(in)    :: hm
    type(geometry_t),     intent(in)    :: geo
    type(states_t),       intent(inout) :: st
    FLOAT,                intent(out)   :: current(:, :, :) !< current(1:der%mesh%np_part, 1:der%mesh%sb%dim, 1:st%d%nspin)
    FLOAT, pointer,       intent(inout) :: current_kpt(:, :, :) !< current(1:der%mesh%np_part, 1:der%mesh%sb%dim, kpt%start:kpt%end)

    integer :: ik, ist, idir, idim, ip, ib, ii, ispin
    CMPLX, allocatable :: gpsi(:, :, :), psi(:, :), hpsi(:, :), rhpsi(:, :), rpsi(:, :), hrpsi(:, :)
    FLOAT, allocatable :: symmcurrent(:, :)
    type(profile_t), save :: prof
    type(symmetrizer_t) :: symmetrizer
    type(batch_t) :: hpsib, rhpsib, rpsib, hrpsib, epsib
    type(batch_t), allocatable :: commpsib(:)
    logical, parameter :: hamiltonian_current = .false.
    FLOAT :: ww
    CMPLX :: c_tmp

    call profiling_in(prof, "CURRENT")
    PUSH_SUB(current_calculate)

    ! spin not implemented or tested
    ASSERT(all(ubound(current) == (/der%mesh%np_part, der%mesh%sb%dim, st%d%nspin/)))
    ASSERT(all(ubound(current_kpt) == (/der%mesh%np_part, der%mesh%sb%dim, st%d%kpt%end/)))
    ASSERT(all(lbound(current_kpt) == (/1, 1, st%d%kpt%start/)))

    SAFE_ALLOCATE(psi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(gpsi(1:der%mesh%np, 1:der%mesh%sb%dim, 1:st%d%dim))
    SAFE_ALLOCATE(hpsi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(rhpsi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(rpsi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(hrpsi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(commpsib(1:der%mesh%sb%dim))

    current = M_ZERO
    current_kpt = M_ZERO

    select case(this%method)

    case(CURRENT_FAST)

      do ik = st%d%kpt%start, st%d%kpt%end
        ispin = states_dim_get_spin_index(st%d, ik)
        do ib = st%group%block_start, st%group%block_end

          call batch_pack(st%group%psib(ib, ik), copy = .true.)
          call batch_copy(st%group%psib(ib, ik), epsib, fill_zeros = .false.)
          call boundaries_set(der%boundaries, st%group%psib(ib, ik))
          
          if(associated(hm%hm_base%phase)) then
            call zhamiltonian_base_phase(hm%hm_base, der, der%mesh%np_part, ik, &
              conjugate = .false., psib = epsib, src = st%group%psib(ib, ik))
          else
            call batch_copy_data(der%mesh%np_part, st%group%psib(ib, ik), epsib)
          end if

          !The call to individual derivatives_perfom routines returns the derivatives along
          !the primitive axis in case of non-orthogonal cells, whereas the code expects derivatives
          !along the Cartesian axis.
          ASSERT(.not.der%mesh%sb%nonorthogonal)
          do idir = 1, der%mesh%sb%dim
            call batch_copy(st%group%psib(ib, ik), commpsib(idir))
            call zderivatives_batch_perform(der%grad(idir), der, epsib, commpsib(idir), set_bc = .false.)
          end do

          
          
          call zhamiltonian_base_nlocal_position_commutator(hm%hm_base, der%mesh, st%d, ik, epsib, commpsib)

          do idir = 1, der%mesh%sb%dim

            if(associated(hm%hm_base%phase)) then
              call zhamiltonian_base_phase(hm%hm_base, der, der%mesh%np_part, ik, conjugate = .true., psib = commpsib(idir))
            end if
            
            do ist = states_block_min(st, ib), states_block_max(st, ib)

              do idim = 1, st%d%dim
                ii = batch_inv_index(st%group%psib(ib, ik), (/ist, idim/))
                call batch_get_state(st%group%psib(ib, ik), ii, der%mesh%np, psi(:, idim))
                call batch_get_state(commpsib(idir), ii, der%mesh%np, hrpsi(:, idim))
              end do
              
              ww = st%d%kweights(ik)*st%occ(ist, ik) 
              if(st%d%ispin /= SPINORS) then
                !$omp parallel do
                do ip = 1, der%mesh%np
                  current_kpt(ip, idir, ik) = &
                    current_kpt(ip, idir, ik) + ww*aimag(conjg(psi(ip, 1))*hrpsi(ip, 1))
                end do
                !$omp end parallel do
              else
                !$omp parallel do private(c_tmp)
                do ip = 1, der%mesh%np
                  current(ip, idir, 1) = current(ip, idir, 1) + &
                    ww*aimag(conjg(psi(ip, 1))*hrpsi(ip, 1))
                  current(ip, idir, 2) = current(ip, idir, 2) + &
                    ww*aimag(conjg(psi(ip, 2))*hrpsi(ip, 2))
                  c_tmp = conjg(psi(ip, 1))*hrpsi(ip, 2) - psi(ip, 2)*conjg(hrpsi(ip, 1))
                  current(ip, idir, 3) = current(ip, idir, 3) + ww* real(c_tmp)
                  current(ip, idir, 4) = current(ip, idir, 4) + ww*aimag(c_tmp)
                end do
                !$omp end parallel do
              end if            
 

 
            end do

            call batch_end(commpsib(idir))

          end do

          call batch_end(epsib)
          call batch_unpack(st%group%psib(ib, ik), copy = .false.)

        end do
      end do
    
    case(CURRENT_HAMILTONIAN)

      do ik = st%d%kpt%start, st%d%kpt%end
        ispin = states_dim_get_spin_index(st%d, ik)
        do ib = st%group%block_start, st%group%block_end

          call batch_pack(st%group%psib(ib, ik), copy = .true.)

          call batch_copy(st%group%psib(ib, ik), hpsib, fill_zeros = .false.)
          call batch_copy(st%group%psib(ib, ik), rhpsib)
          call batch_copy(st%group%psib(ib, ik), rpsib)
          call batch_copy(st%group%psib(ib, ik), hrpsib)

          call boundaries_set(der%boundaries, st%group%psib(ib, ik))
          call zhamiltonian_apply_batch(hm, der, st%group%psib(ib, ik), hpsib, ik, set_bc = .false.)

          do idir = 1, der%mesh%sb%dim

            call batch_mul(der%mesh%np, der%mesh%x(:, idir), hpsib, rhpsib)
            call batch_mul(der%mesh%np_part, der%mesh%x(:, idir), st%group%psib(ib, ik), rpsib)
          
            call zhamiltonian_apply_batch(hm, der, rpsib, hrpsib, ik, set_bc = .false.)

            do ist = states_block_min(st, ib), states_block_max(st, ib)

              do idim = 1, st%d%dim
                ii = batch_inv_index(st%group%psib(ib, ik), (/ist, idim/))
                call batch_get_state(st%group%psib(ib, ik), ii, der%mesh%np, psi(:, idim))
                call batch_get_state(hrpsib, ii, der%mesh%np, hrpsi(:, idim))
                call batch_get_state(rhpsib, ii, der%mesh%np, rhpsi(:, idim))
              end do

              ww = st%d%kweights(ik)*st%occ(ist, ik)              

              if(st%d%ispin /= SPINORS) then
                !$omp parallel do
                do ip = 1, der%mesh%np
                  current_kpt(ip, idir, ik) = current_kpt(ip, idir, ik) &
                    - ww*aimag(conjg(psi(ip, 1))*hrpsi(ip, 1) - conjg(psi(ip, 1))*rhpsi(ip, 1))
                end do
                !$omp end parallel do
              else
                !$omp parallel do  private(c_tmp)
                do ip = 1, der%mesh%np
                  current(ip, idir, 1) = current(ip, idir, 1) + &
                    ww*aimag(conjg(psi(ip, 1))*hrpsi(ip, 1) - conjg(psi(ip, 1))*rhpsi(ip, 1))
                  current(ip, idir, 2) = current(ip, idir, 2) + &
                    ww*aimag(conjg(psi(ip, 2))*hrpsi(ip, 2) - conjg(psi(ip, 2))*rhpsi(ip, 2))
                  c_tmp = conjg(psi(ip, 1))*hrpsi(ip, 2) - conjg(psi(ip, 1))*rhpsi(ip, 2) &
                         -psi(ip, 2)*conjg(hrpsi(ip, 1)) - psi(ip, 2)*conjg(rhpsi(ip, 1))
                  current(ip, idir, 3) = current(ip, idir, 3) + ww* real(c_tmp)
                  current(ip, idir, 4) = current(ip, idir, 4) + ww*aimag(c_tmp)
                end do
                !$omp end parallel do
              end if
  
            end do
            
          end do

          call batch_unpack(st%group%psib(ib, ik), copy = .false.)
          
          call batch_end(hpsib)
          call batch_end(rhpsib)
          call batch_end(rpsib)
          call batch_end(hrpsib)

        end do
      end do
    
    case(CURRENT_GRADIENT, CURRENT_GRADIENT_CORR)

      do ik = st%d%kpt%start, st%d%kpt%end
        ispin = states_dim_get_spin_index(st%d, ik)
        do ist = st%st_start, st%st_end
          
          call states_get_state(st, der%mesh, ist, ik, psi)
          
          do idim = 1, st%d%dim
            call boundaries_set(der%boundaries, psi(:, idim))
          end do

          if(associated(hm%hm_base%phase)) then 
            call states_set_phase(st%d, psi, hm%hm_base%phase(1:der%mesh%np_part, ik), der%mesh%np_part, .false.)
          end if

          do idim = 1, st%d%dim
            call zderivatives_grad(der, psi(:, idim), gpsi(:, :, idim), set_bc = .false.)
          end do
          
          if(this%method == CURRENT_GRADIENT_CORR) then
            !A nonlocal contribution from the MGGA potential must be included
            !This must be done first, as this is like a position-dependent mass 
            if(hm%family_is_mgga_with_exc) then
              do idim = 1, st%d%dim
                do idir = 1, der%mesh%sb%dim
                  !$omp parallel do
                  do ip = 1, der%mesh%np
                    gpsi(ip, idir, idim) = (M_ONE+CNST(2.0)*hm%vtau(ip,ispin))*gpsi(ip, idir, idim)
                  end do
                  !$omp end parallel do
                end do
              end do 
            end if
           
            !A nonlocal contribution from the pseudopotential must be included
            call zprojector_commute_r_allatoms_alldir(hm%ep%proj, geo, der%mesh, st%d%dim, ik, psi, gpsi)                 
            !A nonlocal contribution from the scissor must be included
            if(hm%scissor%apply) then
              call scissor_commute_r(hm%scissor, der%mesh, ik, psi, gpsi)
            end if
            
            if(hm%lda_u_level /= DFT_U_NONE) then
              call zlda_u_commute_r(hm%lda_u, der%mesh, st%d, ik, psi, gpsi, &
                              associated(hm%hm_base%phase))
            end if

          end if

          ww = st%d%kweights(ik)*st%occ(ist, ik)

          if(st%d%ispin /= SPINORS) then
            do idir = 1, der%mesh%sb%dim
              !$omp parallel do
              do ip = 1, der%mesh%np
                current_kpt(ip, idir, ik) = current_kpt(ip, idir, ik) + &
                  ww*aimag(conjg(psi(ip, 1))*gpsi(ip, idir, 1))
              end do
              !$omp end parallel do
            end do
          else
            do idir = 1, der%mesh%sb%dim
              !$omp parallel do  private(c_tmp)
              do ip = 1, der%mesh%np
                current(ip, idir, 1) = current(ip, idir, 1) + &
                  ww*aimag(conjg(psi(ip, 1))*gpsi(ip, idir, 1))
                current(ip, idir, 2) = current(ip, idir, 2) + &
                  ww*aimag(conjg(psi(ip, 2))*gpsi(ip, idir, 2))
                c_tmp = conjg(psi(ip, 1))*gpsi(ip, idir, 2) - psi(ip, 2)*conjg(gpsi(ip, idir, 1))
                current(ip, idir, 3) = current(ip, idir, 3) + ww* real(c_tmp)
                current(ip, idir, 4) = current(ip, idir, 4) + ww*aimag(c_tmp)
              end do
              !$omp end parallel do
            end do
          end if

        end do
      end do
      
    case default

      ASSERT(.false.)

    end select

    if(st%d%ispin /= SPINORS) then
      !We sum the current over k-points
      do ik = st%d%kpt%start, st%d%kpt%end
        ispin = states_dim_get_spin_index(st%d, ik)
        do idir = 1, der%mesh%sb%dim
          !$omp parallel do
          do ip = 1, der%mesh%np
            current(ip, idir, ispin) = current(ip, idir, ispin) + current_kpt(ip, idir, ik)
          end do
          !$omp end parallel do
        end do
      end do 
    end if

    if(st%parallel_in_states .or. st%d%kpt%parallel) then
      ! TODO: this could take dim = (/der%mesh%np, der%mesh%sb%dim, st%d%nspin/)) to reduce the amount of data copied
      call comm_allreduce(st%st_kpt_mpi_grp%comm, current) 
    end if
    
    if(st%symmetrize_density) then
      SAFE_ALLOCATE(symmcurrent(1:der%mesh%np, 1:der%mesh%sb%dim))
      call symmetrizer_init(symmetrizer, der%mesh)
      do ispin = 1, st%d%nspin
        call dsymmetrizer_apply(symmetrizer, der%mesh%np, field_vector = current(:, :, ispin), &
          symmfield_vector = symmcurrent, suppress_warning = .true.)
        current(1:der%mesh%np, 1:der%mesh%sb%dim, ispin) = symmcurrent(1:der%mesh%np, 1:der%mesh%sb%dim)
      end do
      call symmetrizer_end(symmetrizer)
      SAFE_DEALLOCATE_A(symmcurrent)
    end if

    SAFE_DEALLOCATE_A(gpsi)
    SAFE_DEALLOCATE_A(psi)
    SAFE_DEALLOCATE_A(hpsi)
    SAFE_DEALLOCATE_A(rhpsi)
    SAFE_DEALLOCATE_A(rpsi)
    SAFE_DEALLOCATE_A(hrpsi)
    SAFE_DEALLOCATE_A(commpsib)

    call profiling_out(prof)
    POP_SUB(current_calculate)

  end subroutine current_calculate

  
  ! ---------------------------------------------------------
  ! Calculate the current matrix element between two states
  ! I_{ij}(t) = <i| J(t) |j>
  ! This is used only in the floquet_observables utility and 
  ! is highly experimental
  
  subroutine current_calculate_mel(der, hm, geo, psi_i, psi_j, ik,  cmel)
    type(derivatives_t),  intent(inout) :: der
    type(hamiltonian_t),  intent(in)    :: hm
    type(geometry_t),     intent(in)    :: geo
    CMPLX,                intent(in)    :: psi_i(:,:)
    CMPLX,                intent(in)    :: psi_j(:,:)
    integer,              intent(in)    :: ik
    CMPLX,                intent(out)   :: cmel(:,:) ! the current vector cmel(1:der%mesh%sb%dim, 1:st%d%nspin)

    integer ::  idir, idim, ip, ispin
    CMPLX, allocatable :: gpsi_j(:, :, :), ppsi_j(:,:),  gpsi_i(:, :, :), ppsi_i(:,:)

    PUSH_SUB(current_calculate_mel)

    SAFE_ALLOCATE(gpsi_i(1:der%mesh%np, 1:der%mesh%sb%dim, 1:hm%d%dim))
    SAFE_ALLOCATE(ppsi_i(1:der%mesh%np_part,1:hm%d%dim))
    SAFE_ALLOCATE(gpsi_j(1:der%mesh%np, 1:der%mesh%sb%dim, 1:hm%d%dim))
    SAFE_ALLOCATE(ppsi_j(1:der%mesh%np_part,1:hm%d%dim))

    cmel = M_z0

    ispin = states_dim_get_spin_index(hm%d, ik)
    ppsi_i(:,:) = M_z0        
    ppsi_i(1:der%mesh%np,:) = psi_i(1:der%mesh%np,:)    
    ppsi_j(:,:) = M_z0        
    ppsi_j(1:der%mesh%np,:) = psi_j(1:der%mesh%np,:)    

      
    do idim = 1, hm%d%dim
      call boundaries_set(der%boundaries, ppsi_i(:, idim))
      call boundaries_set(der%boundaries, ppsi_j(:, idim))
    end do

    if(associated(hm%hm_base%phase)) then 
      ! Apply the phase that contains both the k-point and vector-potential terms.
      do idim = 1, hm%d%dim
        !$omp parallel do
        do ip = 1, der%mesh%np_part
          ppsi_i(ip, idim) = hm%hm_base%phase(ip, ik)*ppsi_i(ip, idim)
          ppsi_j(ip, idim) = hm%hm_base%phase(ip, ik)*ppsi_j(ip, idim)
        end do
        !$omp end parallel do
      end do
    end if

    do idim = 1, hm%d%dim
      call zderivatives_grad(der, ppsi_i(:, idim), gpsi_i(:, :, idim), set_bc = .false.)
      call zderivatives_grad(der, ppsi_j(:, idim), gpsi_j(:, :, idim), set_bc = .false.)
    end do
    
    !A nonlocal contribution from the MGGA potential must be included
    !This must be done first, as this is like a position-dependent mass 
    if(hm%family_is_mgga_with_exc) then
      do idim = 1, hm%d%dim
        do idir = 1, der%mesh%sb%dim
          !$omp parallel do
          do ip = 1, der%mesh%np
            gpsi_i(ip, idir, idim) = (M_ONE+CNST(2.0)*hm%vtau(ip,ispin))*gpsi_i(ip, idir, idim)
            gpsi_j(ip, idir, idim) = (M_ONE+CNST(2.0)*hm%vtau(ip,ispin))*gpsi_j(ip, idir, idim)
          end do
          !$omp end parallel do
        end do
      end do 
     
      !A nonlocal contribution from the pseudopotential must be included
      call zprojector_commute_r_allatoms_alldir(hm%ep%proj, geo, der%mesh, hm%d%dim, ik, ppsi_i, gpsi_i)                 
      call zprojector_commute_r_allatoms_alldir(hm%ep%proj, geo, der%mesh, hm%d%dim, ik, ppsi_j, gpsi_j)                 
      !A nonlocal contribution from the scissor must be included
      if(hm%scissor%apply) then
        call scissor_commute_r(hm%scissor, der%mesh, ik, ppsi_i, gpsi_i)
        call scissor_commute_r(hm%scissor, der%mesh, ik, ppsi_j, gpsi_j)
      end if

    end if


    do idir = 1, der%mesh%sb%dim
      
      do idim = 1, hm%d%dim
          
        cmel(idir,ispin) = M_zI * zmf_dotp(der%mesh, psi_i(:, idim), gpsi_j(:, idir,idim))
        cmel(idir,ispin) = cmel(idir,ispin) - M_zI * zmf_dotp(der%mesh, gpsi_i(:, idir, idim), psi_j(:, idim))
          
      end do
    end do


    

    SAFE_DEALLOCATE_A(gpsi_i)
    SAFE_DEALLOCATE_A(ppsi_i)
    SAFE_DEALLOCATE_A(gpsi_j)
    SAFE_DEALLOCATE_A(ppsi_j)

    POP_SUB(current_calculate_mel)

  end subroutine current_calculate_mel

  ! ---------------------------------------------------------
  subroutine current_heat_calculate(der, hm, geo, st, current)
    type(derivatives_t),  intent(in)    :: der
    type(hamiltonian_t),  intent(in)    :: hm
    type(geometry_t),     intent(in)    :: geo
    type(states_t),       intent(in)    :: st
    FLOAT,                intent(out)   :: current(:, :, :)

    integer :: ik, ist, idir, idim, ip, ispin, ndim
    CMPLX, allocatable :: gpsi(:, :, :), psi(:, :), g2psi(:, :, :, :)
    CMPLX :: tmp

    PUSH_SUB(current_heat_calculate)

    ASSERT(simul_box_is_periodic(der%mesh%sb))
    ASSERT(st%d%dim == 1)

    ndim = der%mesh%sb%dim
    
    SAFE_ALLOCATE(psi(1:der%mesh%np_part, 1:st%d%dim))
    SAFE_ALLOCATE(gpsi(1:der%mesh%np_part, 1:ndim, 1:st%d%dim))
    SAFE_ALLOCATE(g2psi(1:der%mesh%np, 1:ndim, 1:ndim, 1:st%d%dim))
    
    do ip = 1, der%mesh%np
      current(ip, 1:ndim, 1:st%d%nspin) = st%current(ip, 1:ndim, 1:st%d%nspin)*hm%ep%vpsl(ip)
    end do
    
    
    do ik = st%d%kpt%start, st%d%kpt%end
      ispin = states_dim_get_spin_index(st%d, ik)
      do ist = st%st_start, st%st_end
        
        call states_get_state(st, der%mesh, ist, ik, psi)
        do idim = 1, st%d%dim
          call boundaries_set(der%boundaries, psi(:, idim))
        end do

        if(associated(hm%hm_base%phase)) then 
          call states_set_phase(st%d, psi, hm%hm_base%phase(1:der%mesh%np_part, ik), der%mesh%np_part,  conjugate = .false.)
        end if

        do idim = 1, st%d%dim
          call zderivatives_grad(der, psi(:, idim), gpsi(:, :, idim), set_bc = .false.)
        end do
        do idir = 1, ndim
          if(associated(hm%hm_base%phase)) then 
            call states_set_phase(st%d, gpsi(:, idir, :), hm%hm_base%phase(1:der%mesh%np_part, ik), der%mesh%np, conjugate = .true.)
          end if
            
          !do idim = 1, st%d%dim
          !  call boundaries_set(der%boundaries, psi(:, idim))
          !end do
           
          do idim = 1, st%d%dim
            call boundaries_set(der%boundaries, gpsi(:,idir, idim))
          end do
            
          if(associated(hm%hm_base%phase)) then 
            call states_set_phase(st%d, gpsi(:, idir, :), hm%hm_base%phase(1:der%mesh%np_part, ik), &
                                  der%mesh%np_part,  conjugate = .false.)
          end if
            
          do idim = 1, st%d%dim
            call zderivatives_grad(der, gpsi(:, idir, idim), g2psi(:, :, idir, idim), set_bc = .false.)
          end do
        end do
        idim = 1
        do ip = 1, der%mesh%np
          do idir = 1, ndim
            !tmp = sum(conjg(g2psi(ip, idir, 1:ndim, idim))*gpsi(ip, idir, idim)) - sum(conjg(gpsi(ip, 1:ndim, idim))*g2psi(ip, idir, 1:ndim, idim))
            tmp = sum(conjg(g2psi(ip, 1:ndim, idir, idim))*gpsi(ip, 1:ndim, idim)) - &
                  sum(conjg(gpsi(ip, 1:ndim, idim))*g2psi(ip, 1:ndim, idir, idim))
            tmp = tmp - conjg(gpsi(ip, idir, idim))*sum(g2psi(ip, 1:ndim, 1:ndim, idim)) + &
                  sum(conjg(g2psi(ip, 1:ndim, 1:ndim, idim)))*gpsi(ip, idir, idim)
            current(ip, idir, ispin) = current(ip, idir, ispin) + st%d%kweights(ik)*st%occ(ist, ik)*aimag(tmp)/CNST(8.0)
          end do
        end do
      end do
    end do


    POP_SUB(current_heat_calculate)
      
  end subroutine current_heat_calculate
    

end module current_oct_m

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
