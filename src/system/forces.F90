!! Copyright (C) 2002-2006 M. Marques, A. Castro, A. Rubio, G. Bertsch
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

module forces_oct_m
  use accel_oct_m
  use batch_oct_m
  use batch_ops_oct_m
  use born_charges_oct_m
  use boundaries_oct_m
  use comm_oct_m
  use density_oct_m
  use derivatives_oct_m
  use epot_oct_m
  use geometry_oct_m
  use global_oct_m
  use grid_oct_m
  use hamiltonian_oct_m
  use hamiltonian_base_oct_m
  use io_oct_m
  use kpoints_oct_m
  use lalg_basic_oct_m
  use lasers_oct_m
  use lda_u_oct_m
  use linear_response_oct_m
  use math_oct_m
  use mesh_oct_m
  use mesh_function_oct_m
  use messages_oct_m
  use mpi_oct_m
  use profiling_oct_m
  use projector_oct_m
  use ps_oct_m
  use simul_box_oct_m
  use species_oct_m
  use species_pot_oct_m
  use states_oct_m
  use states_dim_oct_m
  use symm_op_oct_m
  use symmetrizer_oct_m
  use unit_oct_m
  use unit_system_oct_m
  use utils_oct_m
  use v_ks_oct_m
  use vdw_ts_oct_m

  implicit none

  private
  public ::                    &
    forces_calculate,          &
    dforces_from_potential,    &
    zforces_from_potential,    &
    dforces_derivative,        &
    zforces_derivative,        &
    dforces_born_charges,      &
    zforces_born_charges,      &
    total_force_calculate,     &
    forces_costate_calculate,  &
    forces_write_info

  type(profile_t), save :: prof_comm


  type(geometry_t), pointer :: geo_
  type(grid_t), pointer :: gr_
  type(hamiltonian_t), pointer :: hm_
  type(states_t), pointer :: psi_
  type(states_t), pointer :: chi_
  integer, pointer :: j_, ist_, ik_, iatom_
  CMPLX, allocatable :: derpsi_(:, :, :)

contains

  ! ---------------------------------------------------------
  !> This computes the total forces on the ions created by the electrons
  !! (it excludes the force due to possible time-dependent external fields).
  subroutine total_force_calculate(gr, geo, ep, st, x, lda_u)
    type(grid_t),     intent(inout) :: gr
    type(geometry_t), intent(in)    :: geo
    type(epot_t),     intent(inout) :: ep
    type(states_t),   intent(inout) :: st
    FLOAT, intent(inout)            :: x(MAX_DIM)
    integer,          intent(in)    :: lda_u

    type(profile_t), save :: forces_prof

    call profiling_in(forces_prof, "FORCES")
    PUSH_SUB(total_force_calculate)

    x = M_ZERO
    if (states_are_real(st) ) then 
      call dtotal_force_from_potential(gr, geo, ep, st, x, lda_u)
    else
      call ztotal_force_from_potential(gr, geo, ep, st, x, lda_u)
    end if

    POP_SUB(total_force_calculate)
    call profiling_out(forces_prof)
  end subroutine total_force_calculate

  ! -------------------------------------------------------

  subroutine forces_costate_calculate(gr, geo, hm, psi, chi, f, q)
    type(grid_t), target, intent(inout) :: gr
    type(geometry_t), target, intent(inout) :: geo
    type(hamiltonian_t), target, intent(inout) :: hm
    type(states_t), target, intent(inout) :: psi
    type(states_t), target, intent(inout) :: chi
    FLOAT,            intent(inout) :: f(:, :)
    FLOAT,            intent(in)    :: q(:, :)

    integer :: jatom, idim, jdim
    integer, target :: j, ist, ik, iatom
    FLOAT :: r, w2r_, w1r_, xx(MAX_DIM), dq, pdot3p, pdot3m, pdot3p2, pdot3m2, dforce1, dforce2
    type(profile_t), save :: forces_prof
    CMPLX, allocatable :: zpsi(:, :)
    FLOAT, allocatable :: forceks1p(:), forceks1m(:), forceks1p2(:), forceks1m2(:), dforceks1(:)

    call profiling_in(forces_prof, "FORCES")
    PUSH_SUB(forces_costate_calculate)

    ! FIXME: is the next section not basically the same as the routine ion_interaction_calculate?

    f = M_ZERO
    do iatom = 1, geo%natoms
      do jatom = 1, geo%natoms
        if(jatom == iatom) cycle
        xx(1:gr%sb%dim) = geo%atom(jatom)%x(1:gr%sb%dim) - geo%atom(iatom)%x(1:gr%sb%dim)
        r = sqrt( sum( xx(1:gr%sb%dim)**2 ) )
        w2r_ = w2r(geo%atom(iatom)%species, geo%atom(jatom)%species, r)
        w1r_ = w1r(geo%atom(iatom)%species, geo%atom(jatom)%species, r)
        do idim = 1, gr%sb%dim
          do jdim = 1, gr%sb%dim
            f(iatom, idim) = f(iatom, idim) + (q(jatom, jdim) - q(iatom, jdim)) * w2r_ * (M_ONE/r**2) * xx(idim) * xx(jdim)
            f(iatom, idim) = f(iatom, idim) - (q(jatom, jdim) - q(iatom, jdim)) * w1r_ * (M_ONE/r**3) * xx(idim) * xx(jdim)
            if(jdim == idim) then
              f(iatom, idim) = f(iatom, idim) + (q(jatom, jdim) - q(iatom, jdim)) * w1r_ * (M_ONE/r)
            end if
          end do
        end do
      end do
    end do

    SAFE_ALLOCATE(derpsi_(1:gr%mesh%np_part, 1:gr%sb%dim, 1:psi%d%dim))

    dq = CNST(0.001)

    geo_ => geo
    gr_ => gr
    hm_ => hm
    j_ => j
    ist_ => ist
    ik_ => ik
    iatom_ => iatom
    psi_ => psi
    chi_ => chi

    SAFE_ALLOCATE(forceks1p(1:gr%sb%dim))
    SAFE_ALLOCATE(forceks1m(1:gr%sb%dim))
    SAFE_ALLOCATE(forceks1p2(1:gr%sb%dim))
    SAFE_ALLOCATE(forceks1m2(1:gr%sb%dim))
    SAFE_ALLOCATE(dforceks1(1:gr%sb%dim))
    SAFE_ALLOCATE(zpsi(1:gr%mesh%np_part, 1:psi%d%dim))
    
    do ist = 1, psi%nst
      do ik = 1, psi%d%nik
        derpsi_ = M_z0
        call states_get_state(psi, gr%mesh, ist, ik, zpsi)
        call zderivatives_grad(gr%der, zpsi(:, 1), derpsi_(:, :, 1))
        do iatom = 1, geo%natoms
          do j = 1, gr%sb%dim
            call force1(geo%atom(iatom)%x(j) + dq, forceks1p, pdot3p)
            call force1(geo%atom(iatom)%x(j) - dq, forceks1m, pdot3m)
            call force1(geo%atom(iatom)%x(j) + dq/M_TWO, forceks1p2, pdot3p2)
            call force1(geo%atom(iatom)%x(j) - dq/M_TWO, forceks1m2, pdot3m2)
            dforceks1 = ((M_FOUR/M_THREE) * (forceks1p2 - forceks1m2) - (M_ONE / CNST(6.0)) * (forceks1p - forceks1m)) / dq
            dforce1 = sum(q(iatom, :) * dforceks1(:))
            dforce2 = ((M_FOUR/M_THREE) * (pdot3p2 - pdot3m2) - (M_ONE / CNST(6.0)) * (pdot3p - pdot3m)) / dq
            f(iatom, j) = f(iatom, j) - M_TWO * psi%occ(ist, ik) * dforce1 + M_TWO * dforce2
          end do
        end do
      end do
    end do

    SAFE_DEALLOCATE_A(zpsi)
    SAFE_DEALLOCATE_A(forceks1p)
    SAFE_DEALLOCATE_A(forceks1m)
    SAFE_DEALLOCATE_A(forceks1p2)
    SAFE_DEALLOCATE_A(forceks1m2)
    SAFE_DEALLOCATE_A(dforceks1)
    SAFE_DEALLOCATE_A(derpsi_)

    POP_SUB(forces_costate_calculate)
    call profiling_out(forces_prof)

  contains

    FLOAT function wr(speca, specb, r)
      type(species_t), intent(in) :: speca, specb
      FLOAT, intent(in) :: r
      wr = species_zval(speca) * species_zval(specb) / r
    end function wr
    
    FLOAT function w1r(speca, specb, r)
      type(species_t), intent(in) :: speca, specb
      FLOAT, intent(in) :: r
      w1r = - species_zval(speca) * species_zval(specb) / r**2
    end function w1r
    
    FLOAT function w2r(speca, specb, r)
      type(species_t), intent(in) :: speca, specb
      FLOAT, intent(in) :: r
      w2r = M_TWO * species_zval(speca) * species_zval(specb) / r**3
    end function w2r
  end subroutine forces_costate_calculate
  ! ---------------------------------------------------------


  ! ---------------------------------------------------------
  subroutine force1(q, res, pdot3)
    FLOAT, intent(in) :: q
    FLOAT, intent(inout) :: res(:)
    FLOAT, intent(inout) :: pdot3

    integer :: m
    FLOAT :: qold
    CMPLX, allocatable :: viapsi(:, :), zpsi(:, :)

    qold = geo_%atom(iatom_)%x(j_)
    geo_%atom(iatom_)%x(j_) = q
    SAFE_ALLOCATE(viapsi(1:gr_%mesh%np_part, 1:psi_%d%dim))
    SAFE_ALLOCATE(zpsi(1:gr_%mesh%np_part, 1:psi_%d%dim))
    viapsi = M_z0
    call states_get_state(psi_, gr_%mesh, ist_, ik_, zpsi)
    call zhamiltonian_apply_atom (hm_, geo_, gr_, iatom_, zpsi, viapsi)
    
    do m = 1, ubound(res, 1)
      res(m) = real( zmf_dotp(gr_%mesh, viapsi(:, 1), derpsi_(:, m, 1)) , REAL_PRECISION)
    end do

    call states_get_state(chi_, gr_%mesh, ist_, ik_, zpsi)
    pdot3 = real(M_zI * zmf_dotp(gr_%mesh, zpsi(:, 1), viapsi(:, 1)), REAL_PRECISION)
    geo_%atom(iatom_)%x(j_) = qold
    SAFE_DEALLOCATE_A(viapsi)
  end subroutine force1
  ! ---------------------------------------------------------


  ! ---------------------------------------------------------
  subroutine forces_calculate(gr, geo, hm, st, ks, vhxc_old, t, dt)
    type(grid_t),        intent(inout) :: gr
    type(geometry_t),    intent(inout) :: geo
    type(hamiltonian_t), intent(inout) :: hm
    type(states_t),      intent(inout) :: st
    type(v_ks_t),        intent(in)      :: ks
    FLOAT,     optional, intent(in)    :: vhxc_old(:,:)
    FLOAT,     optional, intent(in)    :: t
    FLOAT,     optional, intent(in)    :: dt

    integer :: j, iatom, idir
    FLOAT :: x(MAX_DIM), time, global_force(1:MAX_DIM)
    FLOAT, allocatable :: force(:, :), force_loc(:, :), force_nl(:, :), force_u(:, :)
    FLOAT, allocatable :: force_nlcc(: ,:)
    FLOAT, allocatable :: force_scf(:, :)
    type(profile_t), save :: forces_prof

    call profiling_in(forces_prof, "FORCES")
    PUSH_SUB(forces_calculate)

    x(:) = M_ZERO
    time = M_ZERO
    if(present(t)) time = t

    !We initialize the different components of the force to zero
    do iatom = 1, geo%natoms
      geo%atom(iatom)%f_ii(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_vdw(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_loc(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_nl(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_u(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_fields(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_nlcc(1:gr%sb%dim) = M_ZERO
      geo%atom(iatom)%f_scf(1:gr%sb%dim) = M_ZERO
    end do

    ! the ion-ion and vdw terms are already calculated
    ! if we use vdw TS, we need to compute it now
    if (ks%vdw_correction == OPTION__VDWCORRECTION__VDW_TS ) then
      call vdw_ts_force_calculate(ks%vdw_ts, hm%ep%vdw_forces, geo, gr%der, gr%sb, st, st%rho)
    end if

    do iatom = 1, geo%natoms
      geo%atom(iatom)%f(1:gr%sb%dim) = hm%ep%fii(1:gr%sb%dim, iatom) + hm%ep%vdw_forces(1:gr%sb%dim, iatom)
      geo%atom(iatom)%f_ii(1:gr%sb%dim) = hm%ep%fii(1:gr%sb%dim, iatom)
      geo%atom(iatom)%f_vdw(1:gr%sb%dim) = hm%ep%vdw_forces(1:gr%sb%dim, iatom)
    end do

    if(present(t)) then
      call epot_global_force(hm%ep, geo, time, global_force)

      ! the ion-ion term is already calculated
      do iatom = 1, geo%natoms
        geo%atom(iatom)%f(1:gr%sb%dim) = geo%atom(iatom)%f(1:gr%sb%dim) + global_force(1:gr%sb%dim)
        geo%atom(iatom)%f_ii(1:gr%sb%dim) = geo%atom(iatom)%f_ii(1:gr%sb%dim) + global_force(1:gr%sb%dim)
      end do
    end if

    SAFE_ALLOCATE(force(1:gr%mesh%sb%dim, 1:geo%natoms))
    SAFE_ALLOCATE(force_loc(1:gr%mesh%sb%dim, 1:geo%natoms))
    SAFE_ALLOCATE(force_nl(1:gr%mesh%sb%dim, 1:geo%natoms))
    SAFE_ALLOCATE(force_u(1:gr%mesh%sb%dim, 1:geo%natoms)) 
    SAFE_ALLOCATE(force_scf(1:gr%mesh%sb%dim, 1:geo%natoms))
    SAFE_ALLOCATE(force_nlcc(1:gr%mesh%sb%dim, 1:geo%natoms))

    if (states_are_real(st) ) then 
      call dforces_from_potential(gr, geo, hm, st, force, force_loc, force_nl, force_u)
    else
      call zforces_from_potential(gr, geo, hm, st, force, force_loc, force_nl, force_u)
    end if

    if(associated(st%rho_core)) then
      call forces_from_nlcc(gr, geo, hm, st, force_nlcc)
    else 
      force_nlcc(:, :) = M_ZERO
    end if
    if(present(vhxc_old)) then
      call forces_from_scf(gr, geo, hm, st, force_scf, vhxc_old)
    else
      force_scf = M_ZERO
    end if

    if(hm%ep%force_total_enforce) then
      call forces_set_total_to_zero(geo, force)
      call forces_set_total_to_zero(geo, force_loc)
      call forces_set_total_to_zero(geo, force_nl)
      call forces_set_total_to_zero(geo, force_u)
      call forces_set_total_to_zero(geo, force_scf)
      call forces_set_total_to_zero(geo, force_nlcc)
    end if

    do iatom = 1, geo%natoms
      do idir = 1, gr%mesh%sb%dim
        geo%atom(iatom)%f(idir) = geo%atom(iatom)%f(idir) + force(idir, iatom) &
            + force_scf(idir, iatom) + force_nlcc(idir, iatom)
        geo%atom(iatom)%f_loc(idir) = force_loc(idir, iatom)
        geo%atom(iatom)%f_nl(idir) = force_nl(idir, iatom)
        geo%atom(iatom)%f_u(idir) = force_u(idir, iatom)
        geo%atom(iatom)%f_nlcc(idir) = force_nlcc(idir, iatom)
        geo%atom(iatom)%f_scf(idir) = force_scf(idir, iatom)
      end do
    end do

    SAFE_DEALLOCATE_A(force)
    SAFE_DEALLOCATE_A(force_loc)
    SAFE_DEALLOCATE_A(force_nl)
    SAFE_DEALLOCATE_A(force_u)
    SAFE_DEALLOCATE_A(force_nlcc)
    SAFE_DEALLOCATE_A(force_scf)

    !\todo forces due to the magnetic fields (static and time-dependent)
    if(present(t)) then
      do j = 1, hm%ep%no_lasers
        select case(laser_kind(hm%ep%lasers(j)))
        case(E_FIELD_ELECTRIC)
          x(1:gr%sb%dim) = M_ZERO
          call laser_field(hm%ep%lasers(j), x(1:gr%sb%dim), t)
          do iatom = 1, geo%natoms
            ! Here the proton charge is +1, since the electric field has the usual sign.
            geo%atom(iatom)%f(1:gr%mesh%sb%dim) = geo%atom(iatom)%f(1:gr%mesh%sb%dim) &
             + species_zval(geo%atom(iatom)%species)*x(1:gr%mesh%sb%dim)
            geo%atom(iatom)%f_fields(1:gr%mesh%sb%dim) = species_zval(geo%atom(iatom)%species)*x(1:gr%mesh%sb%dim)
          end do
    
        case(E_FIELD_VECTOR_POTENTIAL)
          ! Forces are correctly calculated only if the time-dependent
          ! vector potential has no spatial dependence.
          ! The full force taking account of the spatial dependence of A should be:
          ! F = q [- dA/dt + v x \nabla x A]

          x(1:gr%sb%dim) = M_ZERO
          call laser_electric_field(hm%ep%lasers(j), x(1:gr%sb%dim), t, dt) !convert in E field (E = -dA/ c dt)
          do iatom = 1, geo%natoms
            ! Also here the proton charge is +1
            geo%atom(iatom)%f(1:gr%mesh%sb%dim) = geo%atom(iatom)%f(1:gr%mesh%sb%dim) &
             + species_zval(geo%atom(iatom)%species)*x(1:gr%mesh%sb%dim)
            geo%atom(iatom)%f_fields(1:gr%mesh%sb%dim) = geo%atom(iatom)%f_fields(1:gr%mesh%sb%dim) &
               + species_zval(geo%atom(iatom)%species)*x(1:gr%mesh%sb%dim)
          end do

        case(E_FIELD_MAGNETIC, E_FIELD_SCALAR_POTENTIAL)
          write(message(1),'(a)') 'The forces are currently not properly calculated if time-dependent'
          write(message(2),'(a)') 'magnetic fields are present.'
          call messages_fatal(2)
        end select
      end do
    end if

    if(associated(hm%ep%E_field)) then
      do iatom = 1, geo%natoms
        ! Here the proton charge is +1, since the electric field has the usual sign.
        geo%atom(iatom)%f(1:gr%mesh%sb%dim) = geo%atom(iatom)%f(1:gr%mesh%sb%dim) &
          + species_zval(geo%atom(iatom)%species)*hm%ep%E_field(1:gr%mesh%sb%dim)
        geo%atom(iatom)%f_fields(1:gr%mesh%sb%dim) = geo%atom(iatom)%f_fields(1:gr%mesh%sb%dim) &
               + species_zval(geo%atom(iatom)%species)*hm%ep%E_field(1:gr%mesh%sb%dim)
      end do
    end if
    
    POP_SUB(forces_calculate)
    call profiling_out(forces_prof)

  end subroutine forces_calculate

  ! ----------------------------------------------------------------------

  subroutine forces_set_total_to_zero(geo, force)
    type(geometry_t),    intent(in)    :: geo
    FLOAT,               intent(inout) :: force(:, :)

    FLOAT, allocatable :: total_force(:)
    integer :: iatom

    PUSH_SUB(forces_set_total_to_zero)

    SAFE_ALLOCATE(total_force(1:geo%space%dim))

    total_force(1:geo%space%dim) = CNST(0.0)
    do iatom = 1, geo%natoms
      total_force(1:geo%space%dim) = total_force(1:geo%space%dim) + force(1:geo%space%dim, iatom)/geo%natoms
    end do

    do iatom = 1, geo%natoms
      force(1:geo%space%dim, iatom) = force(1:geo%space%dim, iatom) - total_force(1:geo%space%dim)
    end do

    SAFE_DEALLOCATE_A(total_force)
    POP_SUB(forces_set_total_to_zero)
  end subroutine forces_set_total_to_zero


 ! ----------------------------------------------------------------------

  subroutine forces_write_info(iunit, geo, sb, dir)
    integer,             intent(in)    :: iunit
    type(geometry_t),    intent(in)    :: geo
    type(simul_box_t),   intent(in)    :: sb
    character(len=*),    intent(in)    :: dir

    integer :: iatom, idir, ii, iunit2
    FLOAT:: rr(1:3), ff(1:3), torque(1:3)

    if(.not.mpi_grp_is_root(mpi_world)) return    

    PUSH_SUB(forces_write_info)

    write(iunit,'(3a)') 'Forces on the ions [', trim(units_abbrev(units_out%force)), "]"
    write(iunit,'(a,10x,99(14x,a))') ' Ion', (index2axis(idir), idir = 1, sb%dim)
    do iatom = 1, geo%natoms
      write(iunit,'(i4,a10,10f15.6)') iatom, trim(species_label(geo%atom(iatom)%species)), &
              (units_from_atomic(units_out%force, geo%atom(iatom)%f(idir)), idir=1, sb%dim)
    end do
    write(iunit,'(1x,100a1)') ("-", ii = 1, 13 + sb%dim * 15)
    write(iunit,'(a14, 10f15.6)') " Max abs force", &
            (units_from_atomic(units_out%force, maxval(abs(geo%atom(1:geo%natoms)%f(idir)))), idir=1, sb%dim)
    write(iunit,'(a14, 10f15.6)') " Total force", &
            (units_from_atomic(units_out%force, sum(geo%atom(1:geo%natoms)%f(idir))), idir=1, sb%dim)

    if(geo%space%dim == 2 .or. geo%space%dim == 3) then
      rr = M_ZERO
      ff = M_ZERO
      torque = M_ZERO
      do iatom = 1, geo%natoms
        rr(1:geo%space%dim) = geo%atom(iatom)%x(1:geo%space%dim)
        ff(1:geo%space%dim) = geo%atom(iatom)%f(1:geo%space%dim)
        torque(1:3) = torque(1:3) + dcross_product(rr, ff)
      end do
      write(iunit,'(a14, 10f15.6)') ' Total torque', &
              (units_from_atomic(units_out%force*units_out%length, torque(idir)), idir = 1, 3)
    end if


    iunit2 = io_open(trim(dir)//'/forces', action='write', position='asis')
    write(iunit2,'(a)') &
      ' # Total force (x,y,z) Ion-Ion (x,y,z) VdW (x,y,z) Local (x,y,z) NL (x,y,z)' // &
      ' Fields (x,y,z) Hubbard(x,y,z) SCF(x,y,z) NLCC(x,y,z)'
    do iatom = 1, geo%natoms
       write(iunit2,'(i4,a10,27e15.6)') iatom, trim(species_label(geo%atom(iatom)%species)), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_ii(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_vdw(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_loc(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_nl(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_fields(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_u(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_scf(idir)), idir=1, sb%dim), &
                 (units_from_atomic(units_out%force, geo%atom(iatom)%f_nlcc(idir)), idir=1, sb%dim)
    end do
    call io_close(iunit2) 

    POP_SUB(forces_write_info)

  end subroutine forces_write_info

 ! ----------------------------------------------------------------------
 ! This routine add the contribution to the forces from the nonlinear core correction
 ! see Eq. 9 of Kronik et al., J. Chem. Phys. 115, 4322 (2001)
subroutine forces_from_nlcc(gr, geo, hm, st, force_nlcc)
  type(grid_t),                   intent(inout) :: gr
  type(geometry_t),               intent(inout) :: geo
  type(hamiltonian_t),            intent(in)    :: hm
  type(states_t),                 intent(inout) :: st
  FLOAT,                          intent(out)   :: force_nlcc(:, :)

  integer :: is, iatom, idir
  FLOAT, allocatable :: drho(:,:)

  PUSH_SUB(forces_from_nlcc)

  SAFE_ALLOCATE(drho(1:gr%mesh%np, 1:gr%mesh%sb%dim))

  force_nlcc = M_ZERO

  do iatom = geo%atoms_dist%start, geo%atoms_dist%end
    call species_get_nlcc_grad(geo%atom(iatom)%species, geo%atom(iatom)%x, gr%mesh, drho)

    do idir = 1, gr%mesh%sb%dim
      do is = 1, hm%d%spin_channels
        force_nlcc(idir, iatom) = force_nlcc(idir, iatom) &
                       -dmf_dotp(gr%mesh, drho(:,idir), hm%vxc(1:gr%mesh%np, is))/st%d%spin_channels
      end do
    end do
  end do

  SAFE_DEALLOCATE_A(drho)

  if(geo%atoms_dist%parallel) call dforces_gather(geo, force_nlcc)

  POP_SUB(forces_from_nlcc)
end subroutine forces_from_nlcc

 ! Implementation of the term from Chan et al.,  Phys. Rev. B 47, 4771 (1993).
 ! Here we make the approximation that the "atomic densities" are just the one 
 ! from the pseudopotential.  
 ! NTD : No idea if this is good or bad, but this is easy to implement 
 !       and works well in practice
subroutine forces_from_scf(gr, geo, hm, st, force_scf, vhxc_old)
  type(grid_t),                   intent(inout) :: gr
  type(geometry_t),               intent(inout) :: geo
  type(hamiltonian_t),            intent(in)    :: hm
  type(states_t),                 intent(inout) :: st
  FLOAT,                          intent(out)   :: force_scf(:, :)
  FLOAT,                          intent(in)    :: vhxc_old(:,:)

  integer :: is, iatom, idir
  FLOAT, allocatable :: dvhxc(:,:), drho(:,:,:)

  PUSH_SUB(forces_from_scf)

  SAFE_ALLOCATE(dvhxc(1:gr%mesh%np, 1:hm%d%spin_channels))
  SAFE_ALLOCATE(drho(1:gr%mesh%np, 1:hm%d%spin_channels, 1:gr%mesh%sb%dim))

  !We average over spin channels
  do is = 1, hm%d%spin_channels
    dvhxc(1:gr%mesh%np, is) = hm%vhxc(1:gr%mesh%np, is) - vhxc_old(1:gr%mesh%np, is)
  end do

  force_scf = M_ZERO

  do iatom = geo%atoms_dist%start, geo%atoms_dist%end
    if(species_type(geo%atom(iatom)%species) == SPECIES_PSEUDO .or. &
        species_type(geo%atom(iatom)%species) ==  SPECIES_PSPIO ) then

      if(ps_has_density(species_ps(geo%atom(iatom)%species))) then

        call species_atom_density_grad(gr%mesh, gr%mesh%sb, geo%atom(iatom), &
                 hm%d%spin_channels, drho)

        do idir = 1, gr%mesh%sb%dim
          do is = 1, hm%d%spin_channels
            force_scf(idir, iatom) = force_scf(idir, iatom) &
                                      -dmf_dotp(gr%mesh, drho(:,is,idir), dvhxc(:,is))
          end do
        end do
      end if
    end if
  end do

  SAFE_DEALLOCATE_A(dvhxc)
  SAFE_DEALLOCATE_A(drho)

  if(geo%atoms_dist%parallel) call dforces_gather(geo, force_scf) 
  
  POP_SUB(forces_from_scf)
end subroutine forces_from_scf


#include "undef.F90"
#include "real.F90"
#include "forces_inc.F90"

#include "undef.F90"
#include "complex.F90"
#include "forces_inc.F90"

end module forces_oct_m

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
