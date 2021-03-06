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


! ---------------------------------------------------------
!> calculates the eigenvalues of the orbitals
subroutine X(calculate_eigenvalues)(hm, der, st)
  type(hamiltonian_t), intent(in)    :: hm
  type(derivatives_t), intent(inout) :: der
  type(states_t),      intent(inout) :: st

  R_TYPE, allocatable :: eigen(:, :)

  PUSH_SUB(X(calculate_eigenvalues))
  
  if(debug%info) then
    write(message(1), '(a)') 'Debug: Calculating eigenvalues.'
    call messages_info(1)
  end if

  st%eigenval = M_ZERO

  SAFE_ALLOCATE(eigen(st%st_start:st%st_end, st%d%kpt%start:st%d%kpt%end))
  call X(calculate_expectation_values)(hm, der, st, eigen)

  st%eigenval(st%st_start:st%st_end, st%d%kpt%start:st%d%kpt%end) = &
    real(eigen(st%st_start:st%st_end, st%d%kpt%start:st%d%kpt%end), REAL_PRECISION)

  call comm_allreduce(st%st_kpt_mpi_grp%comm, st%eigenval)

  SAFE_DEALLOCATE_A(eigen)

  POP_SUB(X(calculate_eigenvalues))
end subroutine X(calculate_eigenvalues)

subroutine X(calculate_expectation_values)(hm, der, st, eigen, terms)
  type(hamiltonian_t), intent(in)    :: hm
  type(derivatives_t), intent(inout) :: der
  type(states_t),      intent(inout) :: st
  R_TYPE,              intent(out)   :: eigen(st%st_start:, st%d%kpt%start:) !< (:st%st_end, :st%d%kpt%end)
  integer, optional,   intent(in)    :: terms

  integer :: ik, minst, maxst, ib
  type(batch_t) :: hpsib
  type(profile_t), save :: prof
  logical :: copy_at_end

  PUSH_SUB(X(calculate_expectation_values))
  
  call profiling_in(prof, "EIGENVALUE_CALC")

  do ik = st%d%kpt%start, st%d%kpt%end
    do ib = st%group%block_start, st%group%block_end

      minst = states_block_min(st, ib)
      maxst = states_block_max(st, ib)

      call batch_copy(st%group%psib(ib, ik), hpsib, fill_zeros = .false.)

      copy_at_end = .false.
      if(hamiltonian_apply_packed(hm, der%mesh)) then
        ! unpack at end only if the status on entry is unpacked
        copy_at_end = .not. batch_is_packed(st%group%psib(ib, ik))
        call batch_pack(st%group%psib(ib, ik))
        call batch_pack(hpsib, copy = .false.)
      end if

      call X(hamiltonian_apply_batch)(hm, der, st%group%psib(ib, ik), hpsib, ik, terms = terms)
      call X(mesh_batch_dotp_vector)(der%mesh, st%group%psib(ib, ik), hpsib, eigen(minst:maxst, ik))        
      if(hamiltonian_apply_packed(hm, der%mesh)) then
        call batch_unpack(st%group%psib(ib, ik), copy = .false.)
      end if

      call batch_end(hpsib, copy = copy_at_end)

    end do
  end do

  call profiling_out(prof)
  POP_SUB(X(calculate_expectation_values))
end subroutine X(calculate_expectation_values)

! ---------------------------------------------------------
FLOAT function X(energy_calc_electronic)(hm, der, st, terms) result(energy)
  type(hamiltonian_t), intent(in)    :: hm
  type(derivatives_t), intent(inout) :: der
  type(states_t),      intent(inout) :: st
  integer,             intent(in)    :: terms

  R_TYPE, allocatable  :: tt(:, :)
 
  PUSH_SUB(X(energy_calc_electronic))

  SAFE_ALLOCATE(tt(st%st_start:st%st_end, st%d%kpt%start:st%d%kpt%end))

  call X(calculate_expectation_values)(hm, der, st, tt, terms = terms)

  energy = states_eigenvalues_sum(st, real(tt, REAL_PRECISION))

  SAFE_DEALLOCATE_A(tt)
  POP_SUB(X(energy_calc_electronic))
end function X(energy_calc_electronic)

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
