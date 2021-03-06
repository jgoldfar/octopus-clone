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

module projector_oct_m
  use atom_oct_m
  use batch_oct_m
  use comm_oct_m
  use geometry_oct_m
  use global_oct_m
  use grid_oct_m
  use hgh_projector_oct_m
  use kb_projector_oct_m
  use kpoints_oct_m
  use mesh_oct_m
  use messages_oct_m
  use mpi_oct_m
  use profiling_oct_m
  use ps_oct_m
  use rkb_projector_oct_m
  use simul_box_oct_m
  use species_oct_m
  use states_dim_oct_m
  use submesh_oct_m

  implicit none

  private
  public ::                    &
    projector_t,               &
    projector_null,            &
    projector_is_null,         &
    projector_is,              &
    projector_init,            &
    projector_init_phases,     &
    projector_build,           &
    projector_end,             &
    dproject_psi,              &
    zproject_psi,              &
    dproject_psi_batch,        &
    zproject_psi_batch,        &
    dproject_sphere,           &
    zproject_sphere,           &
    dprojector_matrix_element, &
    zprojector_matrix_element, &
    dprojector_commute_r,      &
    zprojector_commute_r,      &
    dprojector_commute_r_allatoms_alldir, &
    zprojector_commute_r_allatoms_alldir, &
    dr_project_psi,            &
    zr_project_psi
  
  integer, parameter :: MAX_NPROJECTIONS = 4
  integer, parameter :: MAX_L = 5

  !> The projector data type is intended to hold the local and
  !! non-local parts of the pseudopotentials. The definition of the
  !! action of a projector (which is done through the X(project)
  !! subroutine) depends on the type of the projector. 
  !!
  !! There are four different types: 
  !! - local -> a local operator
  !! - HGH projector -> "normal"
  !! - normal Kleinman-Bylander projector (no spin-orbit)
  !! - relativistic Kleinman-Bylander projector (includes spin-orbit)

  type projector_t
    integer :: type = PROJ_NONE
    integer :: nprojections
    integer :: lmax
    integer :: lloc
    integer :: nik
    integer :: reltype

    type(submesh_t)  :: sphere
    

    !> Only one of the following structures should be used at once
    !! The one to be used depends on the value of type variable
    type(hgh_projector_t), pointer :: hgh_p(:, :) => null()
    type(kb_projector_t),  pointer :: kb_p(:, :)  => null()
    type(rkb_projector_t), pointer :: rkb_p(:, :) => null()
    CMPLX,                 pointer :: phase(:, :) => null()
  end type projector_t

contains

  ! ---------------------------------------------------------
  subroutine projector_null(p)
    type(projector_t), intent(inout) :: p !< valgrind objects to intent(out) due to the initializations above

    PUSH_SUB(projector_null)

    p%type = PROJ_NONE
    call submesh_null(p%sphere)

    POP_SUB(projector_null)

  end subroutine projector_null
  !---------------------------------------------------------


  !---------------------------------------------------------
  logical elemental function projector_is_null(p)
    type(projector_t), intent(in) :: p
    projector_is_null = (p%type == PROJ_NONE)
  end function projector_is_null
  !---------------------------------------------------------

  logical elemental function projector_is(p, type)
    type(projector_t), intent(in) :: p
    integer,           intent(in) :: type
    projector_is = (p%type == type)
  end function projector_is

  !---------------------------------------------------------
  subroutine projector_init(p, mesh, atm, dim, reltype)
    type(projector_t),    intent(inout) :: p
    type(mesh_t),         intent(in)    :: mesh
    type(atom_t), target, intent(in)    :: atm
    integer,              intent(in)    :: dim
    integer,              intent(in)    :: reltype

    type(ps_t), pointer :: ps
    
    PUSH_SUB(projector_init)

    call projector_null(p)
    ps => species_ps(atm%species)

    nullify(p%phase)
    p%reltype = reltype
    p%lmax = ps%lmax

    if(ps%local) then
      p%type = PROJ_NONE
      POP_SUB(projector_init)
      return
    end if

    p%lloc = ps%llocal

    p%type = ps%projector_type

    if(p%type == PROJ_KB .and. reltype == 1) then
      if(ps%kbc == 2) then
        p%type = PROJ_RKB
      else
        call messages_write("Spin-orbit coupling for species '"//trim(species_label(atm%species))//" is not available.")
        call messages_warning()
      end if
    end if
    
    select case(p%type)
    case(PROJ_KB)
      p%nprojections = dim*ps%kbc
    case(PROJ_RKB)
      p%nprojections = 4
    case(PROJ_HGH)
      p%nprojections = 3
    end select

    POP_SUB(projector_init)
  end subroutine projector_init

  !---------------------------------------------

  subroutine projector_init_phases(this, sb, std, vec_pot, vec_pot_var)
    type(projector_t),             intent(inout) :: this
    type(simul_box_t),             intent(in)    :: sb
    type(states_dim_t),            intent(in)    :: std
    FLOAT, optional,  allocatable, intent(in)    :: vec_pot(:) !< (sb%dim)
    FLOAT, optional,  allocatable, intent(in)    :: vec_pot_var(:, :) !< (1:sb%dim, 1:ns)

    integer :: ns, iq, is, ikpoint
    FLOAT   :: kr, kpoint(1:MAX_DIM)
    integer :: ndim

    PUSH_SUB(projector_init_phases)

    ns = this%sphere%np
    ndim = sb%dim

    if(.not. associated(this%phase) .and. ns > 0) then
      SAFE_ALLOCATE(this%phase(1:ns, std%kpt%start:std%kpt%end))
    end if

    do iq = std%kpt%start, std%kpt%end
      ikpoint = states_dim_get_kpoint_index(std, iq)

      ! if this fails, it probably means that sb is not compatible with std
      ASSERT(ikpoint <= kpoints_number(sb%kpoints))
      
      kpoint = M_ZERO
      kpoint(1:ndim) = kpoints_get_point(sb%kpoints, ikpoint)
        
      do is = 1, ns
        ! this is only the correction to the global phase, that can
        ! appear if the sphere crossed the boundary of the cell.
        
        kr = sum(kpoint(1:ndim)*(this%sphere%x(is, 1:ndim) - this%sphere%mesh%x(this%sphere%map(is), 1:ndim)))

        if(present(vec_pot)) then
          if(allocated(vec_pot)) kr = kr + &
            sum(vec_pot(1:ndim)*(this%sphere%x(is, 1:ndim)- this%sphere%mesh%x(this%sphere%map(is), 1:ndim)))
        end if

        if(present(vec_pot_var)) then
          if(allocated(vec_pot_var)) kr = kr + sum(vec_pot_var(1:ndim, this%sphere%map(is))*this%sphere%x(is, 1:ndim))
        end if

        this%phase(is, iq) = exp(-M_zI*kr)
      end do

    end do

    POP_SUB(projector_init_phases)

  end subroutine projector_init_phases

  !---------------------------------------------------------
  subroutine projector_build(p, gr, a, so_strength)
    type(projector_t), intent(inout) :: p
    type(grid_t),      intent(in)    :: gr
    type(atom_t),      intent(in)    :: a
    FLOAT,             intent(in)    :: so_strength

    integer :: ll, mm

    PUSH_SUB(projector_build)

    select case (p%type)

    case (PROJ_HGH)
      SAFE_ALLOCATE(p%hgh_p(0:p%lmax, -p%lmax:p%lmax))
      do ll = 0, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call hgh_projector_null(p%hgh_p(ll, mm))
          call hgh_projector_init(p%hgh_p(ll, mm), p%sphere, p%reltype, a, ll, mm, so_strength)
        end do
      end do

    case (PROJ_KB)
      SAFE_ALLOCATE(p%kb_p(0:p%lmax, -p%lmax:p%lmax))
      do ll = 0, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call kb_projector_null(p%kb_p(ll, mm))
          call kb_projector_init(p%kb_p(ll, mm), p%sphere, gr, a, ll, mm)
        end do
      end do

    case (PROJ_RKB)
      SAFE_ALLOCATE(p%rkb_p(1:p%lmax, -p%lmax:p%lmax))
      do ll = 1, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call rkb_projector_null(p%rkb_p(ll, mm))
          call rkb_projector_init(p%rkb_p(ll, mm), p%sphere, a, ll, mm, so_strength)
        end do
      end do
      ! for rkb, l = 0 is a normal kb
      if(p%lloc /= 0) then
        SAFE_ALLOCATE(p%kb_p(1:1, 1:1))
        call kb_projector_null(p%kb_p(1, 1))
        call kb_projector_init(p%kb_p(1, 1), p%sphere, gr, a, 0, 0)
      end if

    end select

    POP_SUB(projector_build)
  end subroutine projector_build

  !---------------------------------------------------------
  subroutine projector_end(p)
    type(projector_t), intent(inout) :: p

    integer :: ll, mm

    PUSH_SUB(projector_end)

    call submesh_end(p%sphere)

    select case(p%type)
    case(PROJ_HGH)
      do ll = 0, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call hgh_projector_end(p%hgh_p(ll, mm))
        end do
      end do
      SAFE_DEALLOCATE_P(p%hgh_p)

    case(PROJ_KB)
      do ll = 0, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call kb_projector_end(p%kb_p(ll, mm))
        end do
      end do
      SAFE_DEALLOCATE_P(p%kb_p)

    case(PROJ_RKB)
      do ll = 1, p%lmax
        if(ll == p%lloc) cycle
        do mm = -ll, ll
          call rkb_projector_end(p%rkb_p(ll, mm))
        end do
      end do
      SAFE_DEALLOCATE_P(p%rkb_p)
      if(p%lloc /= 0) then
        call kb_projector_end(p%kb_p(1, 1))
        SAFE_DEALLOCATE_P(p%kb_p)
      end if

    end select
    
    p%type = PROJ_NONE

    SAFE_DEALLOCATE_P(p%phase)

    POP_SUB(projector_end)
  end subroutine projector_end

#include "undef.F90"
#include "real.F90"
#include "projector_inc.F90"

#include "undef.F90"
#include "complex.F90"
#include "projector_inc.F90"

end module projector_oct_m



!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
