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

!> supply field and symmfield, and/or field_vector and symmfield_vector
subroutine X(symmetrizer_apply)(this, np, field, field_vector, symmfield, symmfield_vector, &
          suppress_warning, reduced_quantity)
  type(symmetrizer_t), target, intent(in)    :: this
  integer,                     intent(in)    :: np !mesh%np or mesh%fine%np
  R_TYPE,    optional, target, intent(in)    :: field(:) !< (np)
  R_TYPE,    optional, target, intent(in)    :: field_vector(:, :)  !< (np, 3)
  R_TYPE,            optional, intent(out)   :: symmfield(:) !< (np)
  R_TYPE,            optional, intent(out)   :: symmfield_vector(:, :) !< (np, 3)
  logical,           optional, intent(in)    :: suppress_warning !< use to avoid output of discrepancy,
    !! for forces, where this routine is not used to symmetrize something already supposed to be symmetric,
    !! but rather to construct the quantity properly from reduced k-points
  logical,           optional, intent(in)    :: reduced_quantity

  integer :: ip, iop, nops, ipsrc, idir
  FLOAT :: destpoint(1:3), srcpoint(1:3), lsize(1:3), offset(1:3)
  R_TYPE  :: acc, acc_vector(1:3)
  FLOAT   :: weight, maxabsdiff, maxabs
  R_TYPE, pointer :: field_global(:), field_global_vector(:, :)
  type(pv_t), pointer :: vp

  PUSH_SUB(X(symmetrizer_apply))

  ASSERT(present(field) .eqv. present(symmfield))
  ASSERT(present(field_vector) .eqv. present(symmfield_vector))
  ! we will do nothing if following condition is not met!
  ASSERT(present(field) .or. present(field_vector))

  if(present(field)) then
    ASSERT(ubound(field, dim = 1) >= np)
    ASSERT(ubound(symmfield, dim = 1) >= np)
  else
    ASSERT(ubound(field_vector, dim = 1) >= np)
    ASSERT(ubound(symmfield_vector, dim = 1) >= np)
  end if

  ASSERT(associated(this%mesh))
  vp => this%mesh%vp

  ! With domain parallelization, we collect all points of the
  ! 'field' array. This seems reasonable, since we will probably
  ! need almost all points anyway.
  !
  ! The symmfield array is kept locally.

  if(present(field)) then
    if(this%mesh%parallel_in_domains) then
      SAFE_ALLOCATE(field_global(1:this%mesh%np_global))
#ifdef HAVE_MPI
      call vec_allgather(vp, field_global, field)
#endif
    else
      field_global => field
    end if
  end if

  if(present(field_vector)) then
    ASSERT(ubound(field_vector, dim=2) == 3)
    if(this%mesh%parallel_in_domains) then
      SAFE_ALLOCATE(field_global_vector(1:this%mesh%np_global, 1:3))
      do idir = 1, 3
#ifdef HAVE_MPI
        call vec_allgather(vp, field_global_vector(:, idir), field_vector(:, idir))
#endif
      end do
    else
      field_global_vector => field_vector
    end if
  end if

  nops = symmetries_number(this%mesh%sb%symm)
  weight = M_ONE/nops

  lsize(1:3) = dble(this%mesh%idx%ll(1:3))
  offset(1:3) = dble(this%mesh%idx%nr(1, 1:3) + this%mesh%idx%enlarge(1:3))

  do ip = 1, np
    if(this%mesh%parallel_in_domains) then
      ! convert to global point
      destpoint(1:3) = dble(this%mesh%idx%lxyz(vp%local(vp%xlocal + ip - 1), 1:3)) - offset(1:3)
    else
      destpoint(1:3) = dble(this%mesh%idx%lxyz(ip, 1:3)) - offset(1:3)
    end if
    ! offset moves corner of cell to origin, in integer mesh coordinates

    ASSERT(all(destpoint >= 0))
    ASSERT(all(destpoint < lsize))

    ! move to center of cell in real coordinates
    destpoint = destpoint - dble(int(lsize)/2)

    !convert to proper reduced coordinates
    forall(idir = 1:3) destpoint(idir) = destpoint(idir)/lsize(idir)

    if(present(field)) &
      acc = M_ZERO
    if(present(field_vector)) &
      acc_vector(1:3) = M_ZERO

    ! iterate over all points that go to this point by a symmetry operation
    do iop = 1, nops
      srcpoint = symm_op_apply_red(this%mesh%sb%symm%ops(iop), destpoint) 

      !We now come back to what should be an integer, if the symmetric point beloings to the grid
      !At this point, this is already checked
      forall(idir = 1:3) srcpoint(idir) = srcpoint(idir)*lsize(idir)  

      ! move back to reference to origin at corner of cell
      srcpoint = srcpoint + dble(int(lsize)/2)

      ! apply periodic boundary conditions in periodic directions
      do idir = 1, this%mesh%sb%periodic_dim
        if(nint(srcpoint(idir)) < 0 .or. nint(srcpoint(idir)) >= lsize(idir)) then
          srcpoint(idir) = modulo(srcpoint(idir)+M_HALF*SYMPREC, lsize(idir))
        end if
      end do
      ASSERT(all(srcpoint >= -SYMPREC))
      ASSERT(all(srcpoint < lsize))
      srcpoint(1:3) = srcpoint(1:3) + offset(1:3)

      ipsrc = this%mesh%idx%lxyz_inv(nint(srcpoint(1)), nint(srcpoint(2)), nint(srcpoint(3)))

      if(present(field)) then
        acc = acc + field_global(ipsrc)
      end if
      if(present(field_vector)) then
        if(.not.optional_default(reduced_quantity, .false.)) then
          acc_vector(1:3) = acc_vector(1:3) + symm_op_apply_inv_cart(this%mesh%sb%symm%ops(iop), field_global_vector(ipsrc, 1:3))
        else
          acc_vector(1:3) = acc_vector(1:3) + symm_op_apply_inv_red(this%mesh%sb%symm%ops(iop), field_global_vector(ipsrc, 1:3))
        end if
      end if
    end do
    if(present(field)) &
      symmfield(ip) = weight * acc
    if(present(field_vector)) &
      symmfield_vector(ip, 1:3) = weight * acc_vector(1:3)

  end do

  if(.not. optional_default(suppress_warning, .false.)) then
    if(present(field)) then
      maxabs = maxval(abs(field(1:np)))
      maxabsdiff = maxval(abs(field(1:np) - symmfield(1:np)))
      if(maxabsdiff / maxabs > CNST(1e-6)) then
        write(message(1),'(a, es12.5)') 'Symmetrization discrepancy ratio (scalar) = ', maxabsdiff / maxabs
        call messages_warning(1)
      end if
    end if
    
    if(present(field_vector)) then
      maxabs = maxval(abs(field_vector(1:np, 1:3)))
      maxabsdiff = maxval(abs(field_vector(1:np, 1:3) - symmfield_vector(1:np, 1:3)))
      if(maxabsdiff / maxabs > CNST(1e-6)) then
        write(message(1),'(a, es12.5)') 'Symmetrization discrepancy ratio (vector) = ', maxabsdiff / maxabs
        call messages_warning(1)
      end if
    end if
  end if

  if(this%mesh%parallel_in_domains) then
    if(present(field)) then
      SAFE_DEALLOCATE_P(field_global)
    end if
    if(present(field_vector)) then
      SAFE_DEALLOCATE_P(field_global_vector)
    end if
  end if

  POP_SUB(X(symmetrizer_apply))
end subroutine X(symmetrizer_apply)

! -------------------------------------------------------------------------------
subroutine X(symmetrize_tensor_cart)(symm, tensor)
  type(symmetries_t), intent(in)    :: symm
  R_TYPE,             intent(inout) :: tensor(:,:) !< (3, 3)
  
  integer :: iop, nops
  R_TYPE :: tensor_symm(3, 3)
  FLOAT :: tmp(3,3)
  
  PUSH_SUB(X(symmetrize_tensor_cart))

  nops = symmetries_number(symm)
  
  tensor_symm(:,:) = M_ZERO
  do iop = 1, nops
    ! The use of the tmp array is a workaround for a PGI bug
    tmp = symm_op_rotation_matrix_cart(symm%ops(iop))
    tensor_symm(1:3,1:3) = tensor_symm(1:3,1:3) + &
      matmul(matmul(transpose(symm_op_rotation_matrix_cart(symm%ops(iop))), tensor(1:3, 1:3)), tmp)
  end do

  tensor(1:3,1:3) = tensor_symm(1:3,1:3) / nops

  POP_SUB(X(symmetrize_tensor_cart))
end subroutine X(symmetrize_tensor_cart)

! -------------------------------------------------------------------------------
! The magneto-optical response 
! j_\nu = \alpha_{\nu \mu, \gamma} B_\gamma E_\mu has the symmetry of
! e_{\nu \mu \gamma} e_{\alpha \beta \gamma} x_\nu x_\mu x_\alpha x_\beta. 
! The response should not change upon changing signs of any direction(s) (x -> -x).
! However, it should change sign upon permutation in the order of axes (x,y -> y,x).
! Therefore, contribution from a rotation symmetry should be multiplied by the
! determinant of the rotation matrix ignoring signs of the rotation matrix elements.
subroutine X(symmetrize_magneto_optics_cart)(symm, tensor) 
  type(symmetries_t),   intent(in)    :: symm 
  R_TYPE,               intent(inout) :: tensor(:,:,:) !< (3, 3, 3)
  
  integer :: iop, nops
  R_TYPE  :: tensor_symm(3, 3, 3)
  FLOAT   :: rot(3, 3)
  integer :: idir1, idir2, idir3, ndir
  integer :: i1, i2, i3, det
  
  PUSH_SUB(X(symmetrize_magneto_optics_cart))
    
  ndir = 3
  
  nops = symmetries_number(symm)
  
  tensor_symm(:,:,:) = M_ZERO
  
  do iop = 1, nops
    rot = symm_op_rotation_matrix_red(symm%ops(iop))
    det = abs(rot(1,1) * rot(2,2) * rot(3,3)) + abs(rot(1,2) * rot(2,3) * rot(3,1)) &
      + abs(rot(1,3) * rot(2,1) * rot(3,2)) - abs(rot(1,1) * rot(2,3) * rot(3,2)) &
      - abs(rot(1,2) * rot(2,1) * rot(3,3)) - abs(rot(1,3) * rot(2,2) * rot(3,1))
          
    do idir1 = 1, ndir
      do idir2 = 1, ndir
        do idir3 = 1, ndir
          ! change of indices upon rotation
          i1 = abs(1 * rot(1,idir1) + 2 * rot(2,idir1) + 3 * rot(3,idir1))
          i2 = abs(1 * rot(1,idir2) + 2 * rot(2,idir2) + 3 * rot(3,idir2))
          i3 = abs(1 * rot(1,idir3) + 2 * rot(2,idir3) + 3 * rot(3,idir3))
          
          tensor_symm(i1,i2,i3) = tensor_symm(i1,i2,i3) + &
            tensor(idir1,idir2,idir3) * det
        end do
      end do
    end do
  end do
  tensor(1:3,1:3,1:3) = tensor_symm(1:3,1:3,1:3) / nops

  POP_SUB(X(symmetrize_magneto_optics_cart))
end subroutine X(symmetrize_magneto_optics_cart)

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
