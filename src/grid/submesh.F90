!! Copyright (C) 2007 X. Andrade
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
  
module submesh_oct_m
  use batch_oct_m
  use comm_oct_m
  use global_oct_m
  use lalg_basic_oct_m
  use messages_oct_m
  use sort_oct_m
  use mesh_oct_m
  use mpi_oct_m
  use par_vec_oct_m
  use periodic_copy_oct_m
  use profiling_oct_m
  use simul_box_oct_m
    
  implicit none
  private 

  public ::                      &
    submesh_t,                   &
    submesh_null,                &
    submesh_init,                &
    submesh_broadcast,           &    
    submesh_copy,                &
    submesh_get_inv,             &
    submesh_build_global,        &
    submesh_end_global,          &
    dsm_integrate,               &
    zsm_integrate,               &
    dsm_integrate_frommesh,      &
    zsm_integrate_frommesh,      & 
    dsm_nrm2,                    &
    zsm_nrm2,                    &
    submesh_add_to_mesh,         &
    dsubmesh_batch_add,          &
    zsubmesh_batch_add,          &
    submesh_to_mesh_dotp,        &
    dsubmesh_batch_add_matrix,   &
    zsubmesh_batch_add_matrix,   &
    dsubmesh_batch_dotp_matrix,  &
    zsubmesh_batch_dotp_matrix,  &
    submesh_overlap,             &
    dsubmesh_copy_from_mesh,     &
    zsubmesh_copy_from_mesh,     &
    dsubmesh_copy_from_mesh_batch,     &
    zsubmesh_copy_from_mesh_batch,     &
    submesh_end

  type submesh_t
    FLOAT                 :: center(1:MAX_DIM)
    FLOAT                 :: radius
    integer               :: np             !< number of points inside the submesh
    integer               :: np_part        !< number of points inside the submesh including ghost points
    integer,      pointer :: map(:)         !< index in the mesh of the points inside the sphere
    FLOAT,        pointer :: x(:,:)
    type(mesh_t), pointer :: mesh
    logical               :: overlap        !< .true. if the submesh has more than one point that is mapped to a mesh point
    
    integer               :: np_global      !< total number of points in the entire mesh
    FLOAT,    allocatable :: x_global(:,:)  
    integer,  allocatable :: part_v(:)
    integer,  allocatable :: global2local(:)
  end type submesh_t
  
  interface submesh_add_to_mesh
    module procedure ddsubmesh_add_to_mesh, zdsubmesh_add_to_mesh, zzsubmesh_add_to_mesh
  end interface submesh_add_to_mesh

  interface submesh_to_mesh_dotp
    module procedure ddsubmesh_to_mesh_dotp, zdsubmesh_to_mesh_dotp, zzsubmesh_to_mesh_dotp
  end interface submesh_to_mesh_dotp

   type(profile_t), save ::           &
       C_PROFILING_SM_REDUCE,         &
       C_PROFILING_SM_NRM2

contains
  
  subroutine submesh_null(sm)
    type(submesh_t), intent(inout) :: sm !< valgrind objects to intent(out) due to the initializations above

    PUSH_SUB(submesh_null)

    sm%np = -1
    sm%radius = M_ZERO
    nullify(sm%map)
    nullify(sm%x)
    nullify(sm%mesh)

    sm%np_global = -1

    POP_SUB(submesh_null)

  end subroutine submesh_null

  ! -------------------------------------------------------------

  subroutine submesh_init(this, sb, mesh, center, rc)
    type(submesh_t),      intent(inout)  :: this !< valgrind objects to intent(out) due to the initializations above
    type(simul_box_t),    intent(in)     :: sb
    type(mesh_t), target, intent(in)     :: mesh
    FLOAT,                intent(in)     :: center(:)
    FLOAT,                intent(in)     :: rc
    
    FLOAT :: r2, xx(1:MAX_DIM)
    FLOAT, allocatable :: center_copies(:, :), xtmp(:, :)
    integer :: icell, is, isb, ip, ix, iy, iz
    type(profile_t), save :: submesh_init_prof
    type(periodic_copy_t) :: pp
    integer, allocatable :: map_inv(:)
    integer :: nmax(1:MAX_DIM), nmin(1:MAX_DIM)
    integer, allocatable :: order(:)

    
    PUSH_SUB(submesh_init)
    call profiling_in(submesh_init_prof, "SUBMESH_INIT")

    this%mesh => mesh

    this%center(1:sb%dim) = center(1:sb%dim)

    this%radius = rc

    ! The spheres are generated differently for periodic coordinates,
    ! mainly for performance reasons.
    if(.not. simul_box_is_periodic(sb)) then 

      SAFE_ALLOCATE(map_inv(0:this%mesh%np_part))
      map_inv(0:this%mesh%np_part) = 0
      
      nmin = 0
      nmax = 0

      ! get a cube of points that contains the sphere
      nmin(1:sb%dim) = int((center(1:sb%dim) - abs(rc))/mesh%spacing(1:sb%dim)) - 1
      nmax(1:sb%dim) = int((center(1:sb%dim) + abs(rc))/mesh%spacing(1:sb%dim)) + 1

      ! make sure that the cube is inside the grid
      nmin(1:sb%dim) = max(mesh%idx%nr(1, 1:sb%dim), nmin(1:sb%dim))
      nmax(1:sb%dim) = min(mesh%idx%nr(2, 1:sb%dim), nmax(1:sb%dim))

      ! Get the total number of points inside the sphere
      is = 0   ! this index counts inner points
      isb = 0  ! and this one boundary points
      do iz = nmin(3), nmax(3)
        do iy = nmin(2), nmax(2)
          do ix = nmin(1), nmax(1)
            ip = mesh%idx%lxyz_inv(ix, iy, iz)
#if defined(HAVE_MPI)
            if(ip == 0) cycle
            if(mesh%parallel_in_domains) ip = vec_global2local(mesh%vp, ip, mesh%vp%partno)
#endif
            if(ip == 0) cycle
            r2 = sum((mesh%x(ip, 1:sb%dim) - center(1:sb%dim))**2)
            if(r2 <= rc**2) then
              if(ip > mesh%np) then
                ! boundary points are marked as negative values
                isb = isb + 1
                map_inv(ip) = -isb
              else
                is = is + 1
                map_inv(ip) = is
              end if
            end if
          end do
        end do
      end do
      this%np = is
      this%np_part = is + isb
      
      SAFE_ALLOCATE(this%map(1:this%np_part))
      SAFE_ALLOCATE(xtmp(1:this%np_part, 0:sb%dim))
      
      ! Generate the table and the positions
      do iz = nmin(3), nmax(3)
        do iy = nmin(2), nmax(2)
          do ix = nmin(1), nmax(1)
            ip = mesh%idx%lxyz_inv(ix, iy, iz)
#if defined(HAVE_MPI)
            if(ip == 0) cycle
            if(mesh%parallel_in_domains) ip = vec_global2local(mesh%vp, ip, mesh%vp%partno)
#endif
            is = map_inv(ip)
            if(is == 0) cycle
            if(is < 0) then
              ! it is a boundary point, move it to ns+1:ns_part range
              is = -is + this%np
              map_inv(ip) = is
            end if
            this%map(is) = ip
            xtmp(is, 1:sb%dim) = mesh%x(ip, 1:sb%dim) - center(1:sb%dim)
            xtmp(is, 0) = sqrt(sum(xtmp(is, 1:sb%dim)**2))
          end do
        end do
      end do

      SAFE_DEALLOCATE_A(map_inv)

    ! This is the case for a periodic system
    else

      ! Get the total number of points inside the sphere considering
      ! replicas along PBCs

      ! this requires some optimization

      call periodic_copy_init(pp, sb, center(1:sb%dim), rc)
      
      SAFE_ALLOCATE(center_copies(1:sb%dim, 1:periodic_copy_num(pp)))

      do icell = 1, periodic_copy_num(pp)
        center_copies(1:sb%dim, icell) = periodic_copy_position(pp, sb, icell)
      end do

      is = 0
      do ip = 1, mesh%np_part
        do icell = 1, periodic_copy_num(pp)
          xx(1:sb%dim) = mesh%x(ip, 1:sb%dim) - center_copies(1:sb%dim, icell)
          r2 = sum(xx(1:sb%dim)**2)
          if(r2 > rc**2 ) cycle
          is = is + 1
        end do
        if (ip == mesh%np) this%np = is
      end do
      
      this%np_part = is

      SAFE_ALLOCATE(this%map(1:this%np_part))
      SAFE_ALLOCATE(xtmp(1:this%np_part, 0:sb%dim))
            
      !iterate again to fill the tables
      is = 0
      do ip = 1, mesh%np_part
        do icell = 1, periodic_copy_num(pp)
          xx(1:sb%dim) = mesh%x(ip, 1:sb%dim) - center_copies(1:sb%dim, icell)
          r2 = sum(xx(1:sb%dim)**2)
          if(r2 > rc**2 ) cycle
          is = is + 1
          this%map(is) = ip
          xtmp(is, 0) = sqrt(r2)
          xtmp(is, 1:sb%dim) = xx(1:sb%dim)
         end do
      end do

      SAFE_DEALLOCATE_A(center_copies)
      
      call periodic_copy_end(pp)

    end if

    ! now order points for better locality
    
    SAFE_ALLOCATE(order(1:this%np_part))
    SAFE_ALLOCATE(this%x(1:this%np_part, 0:sb%dim))

    forall(ip = 1:this%np_part) order(ip) = ip

    call sort(this%map, order)

    forall(ip = 1:this%np_part) this%x(ip, 0:sb%dim) = xtmp(order(ip), 0:sb%dim)

    !check whether points overlap
    
    this%overlap = .false.
    do ip = 1, this%np_part - 1
      if(this%map(ip) == this%map(ip + 1)) then
        this%overlap = .true.
        exit
      end if
    end do
    
    SAFE_DEALLOCATE_A(order)
    SAFE_DEALLOCATE_A(xtmp)

    call profiling_out(submesh_init_prof)
    POP_SUB(submesh_init)
  end subroutine submesh_init

  ! --------------------------------------------------------------

  subroutine submesh_broadcast(this, mesh, center, radius, root, mpi_grp)
    type(submesh_t),      intent(inout)  :: this
    type(mesh_t), target, intent(in)     :: mesh
    FLOAT,                intent(in)     :: center(:)
    FLOAT,                intent(in)     :: radius
    integer,              intent(in)     :: root
    type(mpi_grp_t),      intent(in)     :: mpi_grp

    integer :: nparray(1:2)
    type(profile_t), save :: prof

    PUSH_SUB(submesh_broadcast)
    call profiling_in(prof, 'SUBMESH_BCAST')
    
    if(root /= mpi_grp%rank) then    
      this%mesh => mesh
      this%center(1:mesh%sb%dim) = center(1:mesh%sb%dim)
      this%radius = radius
    end if

    if(mpi_grp%size > 1) then

      if(root == mpi_grp%rank) nparray = (/this%np, this%np_part/)
#ifdef HAVE_MPI
      call MPI_Bcast(nparray, 2, MPI_INTEGER, root, mpi_grp%comm, mpi_err)
      call MPI_Barrier(mpi_grp%comm, mpi_err)
#endif
      this%np = nparray(1)
      this%np_part = nparray(2)

      if(root /= mpi_grp%rank) then
        SAFE_ALLOCATE(this%map(1:this%np_part))
        SAFE_ALLOCATE(this%x(1:this%np_part, 0:mesh%sb%dim))
      end if

#ifdef HAVE_MPI
      if(this%np_part > 0) then
        call MPI_Bcast(this%map(1), this%np_part, MPI_INTEGER, root, mpi_grp%comm, mpi_err)
        call MPI_Barrier(mpi_grp%comm, mpi_err)
        call MPI_Bcast(this%x(1, 0), this%np_part*(mesh%sb%dim + 1), MPI_FLOAT, root, mpi_grp%comm, mpi_err)
        call MPI_Barrier(mpi_grp%comm, mpi_err)
      end if
#endif

    end if

    call profiling_out(prof)
    POP_SUB(submesh_broadcast)
  end subroutine submesh_broadcast
   
  ! --------------------------------------------------------------

  subroutine submesh_end(this)
    type(submesh_t),   intent(inout)  :: this
    
    PUSH_SUB(submesh_end)

    if( this%np /= -1 ) then
      nullify(this%mesh)
      this%np = -1
      SAFE_DEALLOCATE_P(this%map)
      SAFE_DEALLOCATE_P(this%x)
    end if

    POP_SUB(submesh_end)

  end subroutine submesh_end

  ! --------------------------------------------------------------

  subroutine submesh_copy(sm_in, sm_out)
    type(submesh_t), target,  intent(in)   :: sm_in
    type(submesh_t),          intent(out)  :: sm_out

    PUSH_SUB(submesh_copy)
    
    ASSERT(sm_out%np == -1)

    sm_out%mesh => sm_in%mesh

    sm_out%center = sm_in%center
    sm_out%radius = sm_in%radius

    sm_out%np = sm_in%np
    sm_out%np_part = sm_in%np_part
    
    SAFE_ALLOCATE(sm_out%map(1:sm_out%np_part))
    SAFE_ALLOCATE(sm_out%x(1:sm_out%np_part, 0:ubound(sm_in%x, 2)))

    sm_out%map(1:sm_out%np_part) = sm_in%map(1:sm_in%np_part)
    sm_out%x(1:sm_out%np_part, 0:ubound(sm_in%x, 2)) = sm_in%x(1:sm_in%np_part, 0:ubound(sm_in%x, 2))

    POP_SUB(submesh_copy)

  end subroutine submesh_copy

  ! --------------------------------------------------------------

  subroutine submesh_get_inv(this, map_inv)
    type(submesh_t),      intent(in)   :: this
    integer,              intent(out)  :: map_inv(:)

    integer :: is

    PUSH_SUB(submesh_get_inv)
    
    map_inv(1:this%mesh%np_part) = 0
    forall (is = 1:this%np) map_inv(this%map(is)) = is

    POP_SUB(submesh_get_inv)
  end subroutine submesh_get_inv

  ! --------------------------------------------------------------

  logical pure function submesh_overlap(sm1, sm2) result(overlap)
    type(submesh_t),      intent(in)   :: sm1
    type(submesh_t),      intent(in)   :: sm2
    
    FLOAT :: distance

    ! Temporarily assume all atoms overlap for periodic systems. This
    ! will slow down GPU code, but it is safer for the release version
    ! than the fix in develop.
    if(.not. simul_box_is_periodic(sm1%mesh%sb)) then
      distance = sum((sm1%center(1:sm1%mesh%sb%dim) - sm2%center(1:sm2%mesh%sb%dim))**2)
      overlap = distance + CNST(100.0)*M_EPSILON <= (sm1%radius + sm2%radius)**2
    else
      overlap = .true.
    end if

  end function submesh_overlap

  ! -------------------------------------------------------------

    subroutine submesh_build_global(this)
    type(submesh_t),      intent(inout)   :: this

    integer, allocatable :: part_np(:)
    integer :: ipart, ind, ip

    PUSH_SUB(submesh_build_global)

    if(.not. this%mesh%parallel_in_domains) then
      POP_SUB(submesh_build global)
      return
    end if 

    SAFE_ALLOCATE(part_np(this%mesh%vp%npart))
    part_np = 0
    part_np(this%mesh%vp%partno) = this%np

  #if defined(HAVE_MPI)
    call comm_allreduce(this%mesh%mpi_grp%comm, part_np)
  #endif 
    this%np_global = sum(part_np)
    !The 0 index correspond to the local index
    SAFE_ALLOCATE(this%x_global(1:this%np_global, 1:this%mesh%sb%dim))
    SAFE_ALLOCATE(this%part_v(1:this%np_global))
    SAFE_ALLOCATE(this%global2local(1:this%np_global))
    this%x_global = M_ZERO
    this%part_v = 0
    this%global2local = 0

    ind = 0
    do ipart = 1, this%mesh%vp%npart
      if(ipart == this%mesh%vp%partno) then
        do ip = 1, this%np
          this%x_global(ind + ip, 1:this%mesh%sb%dim) = this%x(ip,1:this%mesh%sb%dim)
          this%part_v(ind+ip) = this%mesh%vp%partno
          this%global2local(ind+ip) = ip
        end do
      end if
      ind = ind + part_np(ipart)
    end do 

   #if defined(HAVE_MPI)
    call comm_allreduce(this%mesh%mpi_grp%comm, this%x_global)
    call comm_allreduce(this%mesh%mpi_grp%comm, this%part_v)
    call comm_allreduce(this%mesh%mpi_grp%comm, this%global2local)
   #endif 

    SAFE_DEALLOCATE_A(part_np)

    POP_SUB(submesh_build_global)
  end subroutine submesh_build_global


  subroutine submesh_end_global(this)
    type(submesh_t),      intent(inout)   :: this

    PUSH_SUB(submesh_end_global)

    SAFE_DEALLOCATE_A(this%x_global)
    this%np_global = -1
    SAFE_DEALLOCATE_A(this%part_v)
    SAFE_DEALLOCATE_A(this%global2local)

    POP_SUB(submesh_end_global)
  end subroutine submesh_end_global

  
  ! -----------------------------------------------------------
  
  subroutine zzsubmesh_add_to_mesh(this, sphi, phi, factor)
    type(submesh_t),  intent(in)    :: this
    CMPLX,            intent(in)    :: sphi(:)
    CMPLX,            intent(inout) :: phi(:)
    CMPLX,  optional, intent(in)    :: factor
    
    integer :: ip, m
    
    PUSH_SUB(zzdsubmesh_add_to_mesh)
   
    if(present(factor)) then
      !Loop unrolling inspired by BLAS axpy routine
      m = mod(this%np,4)
      do ip = 1, m
        phi(this%map(ip)) = phi(this%map(ip)) + factor*sphi(ip)
      end do
      if( this%np.ge.4) then
        do ip = m+1, this%np, 4
          phi(this%map(ip))   = phi(this%map(ip))   + factor*sphi(ip)
          phi(this%map(ip+1)) = phi(this%map(ip+1)) + factor*sphi(ip+1)
          phi(this%map(ip+2)) = phi(this%map(ip+2)) + factor*sphi(ip+2)
          phi(this%map(ip+3)) = phi(this%map(ip+3)) + factor*sphi(ip+3)
        end do
      end if
    else
      m = mod(this%np,4)
      do ip = 1, m
        phi(this%map(ip)) = phi(this%map(ip)) + sphi(ip)
      end do
      if( this%np.ge.4) then
        do ip = m+1, this%np, 4
          phi(this%map(ip))   = phi(this%map(ip))   + sphi(ip)
          phi(this%map(ip+1)) = phi(this%map(ip+1)) + sphi(ip+1)
          phi(this%map(ip+2)) = phi(this%map(ip+2)) + sphi(ip+2)
          phi(this%map(ip+3)) = phi(this%map(ip+3)) + sphi(ip+3)
        end do
      end if
    end if 
    
    POP_SUB(zzdsubmesh_add_to_mesh)
  end subroutine zzsubmesh_add_to_mesh


  !------------------------------------------------------------

  CMPLX function zzsubmesh_to_mesh_dotp(this, sphi, phi, reduce) result(dotp)
    type(submesh_t),   intent(in) :: this
    CMPLX,             intent(in) :: sphi(:)
    CMPLX,             intent(in) :: phi(:)
    logical, optional, intent(in) :: reduce
  
    integer :: is, m, ip
  
    PUSH_SUB(zzsubmesh_to_mesh_dotp)
  
    dotp = cmplx(M_ZERO, M_ZERO)
  
    if(this%mesh%use_curvilinear) then
      do is = 1, this%np
        dotp = dotp + this%mesh%vol_pp(this%map(is))*phi(this%map(is))*conjg(sphi(is))
      end do
    else
      m = mod(this%np,4)
      do ip = 1, m
        dotp = dotp + phi(this%map(ip))*conjg(sphi(ip))
      end do
      if( this%np.ge.4) then
        do ip = m+1, this%np, 4
          dotp = dotp + phi(this%map(ip))*conjg(sphi(ip))     &
                      + phi(this%map(ip+1))*conjg(sphi(ip+1)) &
                      + phi(this%map(ip+2))*conjg(sphi(ip+2)) &
                      + phi(this%map(ip+3))*conjg(sphi(ip+3))
        end do
      end if
        dotp = dotp*this%mesh%vol_pp(1)
    end if
  
    if(optional_default(reduce, .true.) .and. this%mesh%parallel_in_domains) then
      call profiling_in(C_PROFILING_SM_REDUCE, "SM_REDUCE")
      call comm_allreduce(this%mesh%vp%comm, dotp)
      call profiling_out(C_PROFILING_SM_REDUCE)
    end if 
 
    POP_SUB(zzsubmesh_to_mesh_dotp)
  end function zzsubmesh_to_mesh_dotp


#include "undef.F90"
#include "real.F90"
#include "submesh_inc.F90"

#include "undef.F90"
#include "complex.F90"
#include "submesh_inc.F90"

end module submesh_oct_m

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
