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
subroutine X(eigensolver_evolution) (gr, st, hm, tol, niter, converged, ik, diff, tau)
  type(grid_t),        target, intent(in)    :: gr
  type(states_t),              intent(inout) :: st
  type(hamiltonian_t), target, intent(in)    :: hm
  FLOAT,                       intent(in)    :: tol
  integer,                     intent(inout) :: niter
  integer,                     intent(inout) :: converged
  integer,                     intent(in)    :: ik
  FLOAT,                       intent(out)   :: diff(:) !< (1:st%nst)
  FLOAT,                       intent(in)    :: tau

  integer :: ist, iter, maxiter, conv, matvec, i, j
  R_TYPE, allocatable :: hpsi(:, :), c(:, :), psi(:, :)
  FLOAT, allocatable :: eig(:)
  type(exponential_t) :: te

  PUSH_SUB(X(eigensolver_evolution))

  maxiter = niter
  matvec = 0

  call exponential_init(te)

  SAFE_ALLOCATE(psi(1:gr%mesh%np_part, 1:st%d%dim))
  SAFE_ALLOCATE(hpsi(1:gr%mesh%np_part, 1:st%d%dim))
  SAFE_ALLOCATE(c(1:st%nst, 1:st%nst))
  SAFE_ALLOCATE(eig(1:st%nst))

  ! Warning: it seems that the algorithm is improved if some extra states are added -- states
  ! whose convergence should not be checked.
  conv = converged

  do iter = 1, maxiter

    do ist = conv + 1, st%nst
      call states_get_state(st, gr%mesh, ist, ik, psi)
      !TODO: convert this opperation to batched versions 
      call exponentiate(psi, j)
      call states_set_state(st, gr%mesh, ist, ik, psi)
      matvec = matvec + j
    end do

    ! This is the orthonormalization suggested by Aichinger and Krotschek
    ! [Comp. Mat. Science 34, 188 (2005)]
    call X(states_calc_overlap)(st, gr%mesh, ik, c)

    call lalg_eigensolve(st%nst, c, eig)

    do i = 1, st%nst
      c(1:st%nst, i) = c(1:st%nst, i)/sqrt(eig(i))
    end do

    call states_rotate(gr%mesh, st, c, ik)
    
    ! Get the eigenvalues and the residues.
    do ist = conv + 1, st%nst
      call states_get_state(st, gr%mesh, ist, ik, psi)
      !TODO: convert these opperations to batched versions 
      call X(hamiltonian_apply)(hm, gr%der, psi, hpsi, ist, ik)
      st%eigenval(ist, ik) = real(X(mf_dotp)(gr%mesh, st%d%dim, psi, hpsi), REAL_PRECISION)
      diff(ist) = X(states_residue)(gr%mesh, st%d%dim, hpsi, st%eigenval(ist, ik), psi)

      if(debug%info) then
        write(message(1), '(a,i4,a,i4,a,i4,a,es12.6)') 'Debug: Evolution Eigensolver - ik', ik, &
          ' ist ', ist, ' iter ', iter, ' res ', diff(ist)
        call messages_info(1)
      end if
    end do

    ! And check for convergence. Note that they must be converged *in order*, so that they can be frozen.
    do ist = conv + 1, st%nst
      if( (diff(ist) < tol) .and. (ist == conv + 1) ) conv = conv + 1
    end do
    if(conv == st%nst) exit
  end do

  converged = conv

  niter = matvec
  call exponential_end(te)

  SAFE_DEALLOCATE_A(psi)
  SAFE_DEALLOCATE_A(hpsi)
  SAFE_DEALLOCATE_A(c)
  SAFE_DEALLOCATE_A(eig)

  POP_SUB(X(eigensolver_evolution))
contains

  ! ---------------------------------------------------------
  subroutine exponentiate(psi, order)
    R_TYPE, target, intent(inout) :: psi(:, :)
    integer,        intent(out)   :: order
    
    CMPLX,          pointer       :: zpsi(:, :)

    PUSH_SUB(X(eigensolver_evolution).exponentiate)

#if defined(R_TREAL)
    SAFE_ALLOCATE(zpsi(1:gr%mesh%np_part, 1:st%d%dim))
    zpsi(1:gr%mesh%np, 1:st%d%dim) = psi(1:gr%mesh%np, 1:st%d%dim)
#else
    zpsi => psi
#endif
    call exponential_apply(te, gr%der, hm, zpsi, ist, ik, -tau, order = order, imag_time = .true.)
#if defined(R_TREAL)
    psi(1:gr%mesh%np, 1:st%d%dim) = R_TOTYPE(zpsi(1:gr%mesh%np, 1:st%d%dim))
    SAFE_DEALLOCATE_P(zpsi)
#else
    nullify(zpsi)
#endif

    POP_SUB(X(eigensolver_evolution).exponentiate)
  end subroutine exponentiate

end subroutine X(eigensolver_evolution)


!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
