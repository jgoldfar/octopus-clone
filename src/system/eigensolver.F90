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

module eigensolver_oct_m
  use batch_oct_m
  use derivatives_oct_m
  use eigen_cg_oct_m
  use eigen_lobpcg_oct_m
  use eigen_rmmdiis_oct_m
  use exponential_oct_m
  use global_oct_m
  use grid_oct_m
  use hamiltonian_oct_m
  use lalg_adv_oct_m
  use lalg_basic_oct_m
  use loct_oct_m
  use mesh_oct_m
  use mesh_function_oct_m
  use messages_oct_m
  use mpi_oct_m
  use mpi_lib_oct_m
  use parser_oct_m
  use preconditioners_oct_m
  use profiling_oct_m
  use states_oct_m
  use states_calc_oct_m
  use states_dim_oct_m
  use subspace_oct_m
  use unit_oct_m
  use unit_system_oct_m
  use xc_oct_m

  implicit none

  private
  public ::            &
    eigensolver_t,     &
    eigensolver_init,  &
    eigensolver_end,   &
    eigensolver_run

  type eigensolver_t
    integer :: es_type    !< which eigensolver to use

    FLOAT   :: tolerance
    integer :: es_maxiter

    FLOAT   :: current_rel_dens_error
    FLOAT   :: imag_time

    !> Stores information about how well it performed.
    FLOAT, pointer   :: diff(:, :)
    integer          :: matvec
    integer, pointer :: converged(:)

    !> Stores information about the preconditioning.
    type(preconditioner_t) :: pre

    type(subspace_t) :: sdiag

    type(xc_t), pointer :: xc

    integer :: rmmdiis_minimization_iter

    logical :: skip_finite_weight_kpoints
    logical :: folded_spectrum
    FLOAT, pointer   :: spectrum_shift(:,:)

    ! cg options
    logical :: orthogonalize_to_all
    integer :: conjugate_direction
    logical :: additional_terms
  end type eigensolver_t


  integer, public, parameter :: &
       RS_PLAN    = 11,         &
       RS_CG      =  5,         &
       RS_CG_NEW  =  6,         &
       RS_EVO     =  9,         &
       RS_LOBPCG  =  8,         &
       RS_RMMDIIS = 10,         &
       RS_ARPACK  = 12,         &
       RS_FEAST   = 13,         &
       RS_PSD     = 14
  
contains

  ! ---------------------------------------------------------
  subroutine eigensolver_init(eigens, gr, st, xc)
    type(eigensolver_t), intent(out)   :: eigens
    type(grid_t),        intent(in)    :: gr
    type(states_t),      intent(in)    :: st
    type(xc_t), target,  intent(in)    :: xc

    integer :: default_iter, default_es
    FLOAT   :: default_tol
    real(8) :: mem

    PUSH_SUB(eigensolver_init)

    !%Variable Eigensolver
    !%Type integer
    !%Section SCF::Eigensolver
    !%Description
    !% Which eigensolver to use to obtain the lowest eigenvalues and
    !% eigenfunctions of the Kohn-Sham Hamiltonian. The default is
    !% conjugate gradients (<tt>cg</tt>), except that when parallelization in states is
    !% enabled, the default is <tt>lobpcg</tt>.
    !%Option cg 5
    !% Conjugate-gradients algorithm.
    !%Option plan 11
    !% Preconditioned Lanczos scheme. Ref: Y. Saad, A. Stathopoulos, J. Chelikowsky, K. Wu and S. Ogut,
    !% "Solution of Large Eigenvalue Problems in Electronic Structure Calculations", <i>BIT</i> <b>36</b>, 1 (1996).
    !%Option cg_new 6
    !% An alternative conjugate-gradients eigensolver, faster for
    !% larger systems but less mature.
    !% Ref: Jiang et al., <i>Phys. Rev. B</i> <b>68</b>, 165337 (2003)
    !%Option evolution 9
    !% (Experimental) Propagation in imaginary time.
    !%Option lobpcg 8
    !% (Experimental) Locally optimal block-preconditioned
    !% conjugate-gradient algorithm. Ref: A. Knyazev, Toward the
    !% Optimal Preconditioned Eigensolver: Locally Optimal Block
    !% Preconditioned Conjugate Gradient Method, <i>SIAM Journal on
    !% Scientific Computing</i>, 23(2):517-541, 2001.  
    !%Option rmmdiis 10 
    !% Residual minimization scheme, direct inversion in the
    !% iterative subspace eigensolver, based on the implementation of
    !% Kresse and Furthm&uuml;ller [<i>Phys. Rev. B</i> <b>54</b>, 11169
    !% (1996)]. This eigensolver requires almost no orthogonalization
    !% so it can be considerably faster than the other options for
    !% large systems; however it might suffer stability problems. To
    !% improve its performance a large number of <tt>ExtraStates</tt>
    !% are required (around 10-20% of the number of occupied states).
    !% Note: with <tt>unocc</tt>, you will need to stop the calculation
    !% by hand, since the highest states will probably never converge.
    !% Usage with more than one block of states per node is experimental, unfortunately.
    !%Option psd 14
    !% (Experimental) Precondtioned steepest descent optimization of the eigenvectors.
    !%End

    if(st%parallel_in_states) then
      default_es = RS_LOBPCG
    else
      default_es = RS_CG
    end if

    call parse_variable('Eigensolver', default_es, eigens%es_type)

    if(st%parallel_in_states .and. .not. eigensolver_parallel_in_states(eigens)) then
      message(1) = "The selected eigensolver is not parallel in states."
      message(2) = "Please use the lobpcg, psd, or rmmdiis eigensolvers."
      call messages_fatal(2)
    end if

    if(eigens%es_type == RS_LOBPCG .and. st%group%block_start /= st%group%block_end) &
      call messages_experimental("lobpcg eigensolver with more than one block per node")

    call messages_obsolete_variable('EigensolverVerbose')
    call messages_obsolete_variable('EigensolverSubspaceDiag', 'SubspaceDiagonalization')

    default_iter = 25
    default_tol = CNST(1e-6)

    select case(eigens%es_type)
    case(RS_CG_NEW)
    case(RS_CG)
      !%Variable CGOrthogonalizeAll
      !%Type logical
      !%Default no
      !%Section SCF::Eigensolver
      !%Description
      !% Used by the cg solver only.
      !% During the cg iterations, the current band can be orthogonalized
      !% against all other bands or only against the lower bands. Orthogonalizing
      !% against all other bands can improve convergence properties, whereas
      !% orthogonalizing against lower bands needs less operations.
      !%End
      call parse_variable('CGOrthogonalizeAll', .false., eigens%orthogonalize_to_all)

      !%Variable CGDirection
      !%Type integer
      !%Section SCF::Eigensolver
      !%Description
      !% Used by the cg solver only.
      !% The conjugate direction is updated using a certain coefficient to the previous
      !% direction. This coeffiction can be computed in different ways. The default is
      !% to use Fletcher-Reeves (FR), an alternative is Polak-Ribiere (PR).
      !%Option fletcher 1
      !% The coefficient for Fletcher-Reeves consists of the current norm of the
      !% steepest descent vector divided by that of the previous iteration.
      !%Option polak 2
      !% For the Polak-Ribiere scheme, a product of the current with the previous
      !% steepest descent vector is subtracted in the nominator.
      !%End
      call parse_variable('CGDirection', OPTION__CGDIRECTION__FLETCHER, eigens%conjugate_direction)

      !%Variable CGAdditionalTerms
      !%Type logical
      !%Section SCF::Eigensolver
      !%Default no
      !%Description
      !% Used by the cg solver only.
      !% Add additional terms during the line minimization, see PTA92, eq. 5.31ff.
      !% These terms can improve convergence for some systems, but they are quite costly.
      !% If you experience convergence problems, you might try out this option.
      !% This feature is still experimental.
      !%End
      call parse_variable('CGAdditionalTerms', .false., eigens%additional_terms)
      if(eigens%additional_terms) then
        call messages_experimental("The additional terms for the CG eigensolver are not tested for all cases.")
      end if

    case(RS_PLAN)
    case(RS_EVO)
      call messages_experimental("imaginary-time evolution eigensolver")

      !%Variable EigensolverImaginaryTime
      !%Type float
      !%Default 10.0
      !%Section SCF::Eigensolver
      !%Description
      !% The imaginary-time step that is used in the imaginary-time evolution
      !% method (<tt>Eigensolver = evolution</tt>) to obtain the lowest eigenvalues/eigenvectors.
      !% It must satisfy <tt>EigensolverImaginaryTime > 0</tt>.
      !%End
      call parse_variable('EigensolverImaginaryTime', CNST(10.0), eigens%imag_time)
      if(eigens%imag_time <= M_ZERO) call messages_input_error('EigensolverImaginaryTime')
    case(RS_LOBPCG)
    case(RS_RMMDIIS)
      default_iter = 3

      !%Variable EigensolverMinimizationIter
      !%Type integer
      !%Default 5
      !%Section SCF::Eigensolver
      !%Description
      !% During the first iterations, the RMMDIIS eigensolver requires
      !% some steepest-descent minimizations to improve
      !% convergence. This variable determines the number of those
      !% minimizations.
      !%End

      call parse_variable('EigensolverMinimizationIter', 5, eigens%rmmdiis_minimization_iter)

      if(gr%mesh%use_curvilinear) call messages_experimental("RMMDIIS eigensolver for curvilinear coordinates")

    case(RS_PSD)
      default_iter = 18
      call messages_experimental("preconditioned steepest descent (PSD) eigensolver")

    case default
      call messages_input_error('Eigensolver')
    end select

    call messages_print_stress(stdout, 'Eigensolver')

    call messages_print_var_option(stdout, "Eigensolver", eigens%es_type)

    call messages_obsolete_variable('EigensolverInitTolerance', 'EigensolverTolerance')
    call messages_obsolete_variable('EigensolverFinalTolerance', 'EigensolverTolerance')
    call messages_obsolete_variable('EigensolverFinalToleranceIteration')

    ! this is an internal option that makes the solver use the 
    ! folded operator (H-shift)^2 to converge first eigenvalues around
    ! the values of shift 
    ! c.f. L. W. Wang and A. Zunger 
    ! JCP 100, 2394 (1994); doi: http://dx.doi.org/10.1063/1.466486
    eigens%folded_spectrum = .false.

    !%Variable EigensolverTolerance
    !%Type float
    !%Section SCF::Eigensolver
    !%Description
    !% This is the tolerance for the eigenvectors. The default is 1e-6,
    !% except for the ARPACK solver for which it is 0.
    !%End
    call parse_variable('EigensolverTolerance', default_tol, eigens%tolerance)

    !%Variable EigensolverMaxIter
    !%Type integer
    !%Section SCF::Eigensolver
    !%Description
    !% Determines the maximum number of iterations that the
    !% eigensolver will perform if the desired tolerance is not
    !% achieved. The default is 25 iterations for all eigensolvers
    !% except for <tt>rmdiis</tt>, which performs only 3 iterations (only
    !% increase it if you know what you are doing).
    !%End
    call parse_variable('EigensolverMaxIter', default_iter, eigens%es_maxiter)
    if(eigens%es_maxiter < 1) call messages_input_error('EigensolverMaxIter')

    if(eigens%es_maxiter > default_iter) then
      call messages_write('You have specified a large number of eigensolver iterations (')
      call messages_write(eigens%es_maxiter)
      call messages_write(').', new_line = .true.)
      call messages_write('This is not a good idea as it might slow down convergence, even for', new_line = .true.)
      call messages_write('independent particles, as subspace diagonalization will not be used', new_line = .true.)
      call messages_write('often enough.')
      call messages_warning()
    end if

    select case(eigens%es_type)
    case(RS_PLAN, RS_CG, RS_LOBPCG, RS_RMMDIIS, RS_PSD)
      call preconditioner_init(eigens%pre, gr)
    case default
      call preconditioner_null(eigens%pre)
    end select

    nullify(eigens%diff)
    SAFE_ALLOCATE(eigens%diff(1:st%nst, 1:st%d%nik))
    eigens%diff(1:st%nst, 1:st%d%nik) = 0

    SAFE_ALLOCATE(eigens%converged(1:st%d%nik))
    eigens%converged(1:st%d%nik) = 0
    eigens%matvec = 0

    ! FEAST: subspace diagonalization or not?  I guess not.
    ! But perhaps something could be gained by changing this.
    call subspace_init(eigens%sdiag, st, no_sd = .false.)

    ! print memory requirements
    select case(eigens%es_type)
    case(RS_RMMDIIS)
      call messages_write('Info: The rmmdiis eigensolver requires ')
      mem = (2.0_8*eigens%es_maxiter - 1.0_8)*st%d%block_size*dble(gr%mesh%np_part)
      if(states_are_real(st)) then
        mem = mem*CNST(8.0)
      else
        mem = mem*CNST(16.0)
      end if
      call messages_write(mem, units = unit_megabytes, fmt = '(f9.1)')
      call messages_write(' of additional')
      call messages_new_line()
      call messages_write('      memory.  This amount can be reduced by decreasing the value')
      call messages_new_line()
      call messages_write('      of the variable StatesBlockSize (currently set to ')
      call messages_write(st%d%block_size)
      call messages_write(').')
      call messages_info()
    end select

    call messages_print_stress(stdout)

    !%Variable EigensolverSkipKpoints
    !%Type logical
    !%Section SCF::Eigensolver
    !%Description
    !% Only solve Hamiltonian for k-points with zero weight
    !%End
    call parse_variable('EigensolverSkipKpoints', .false., eigens%skip_finite_weight_kpoints)
    call messages_print_var_value(stdout,'EigensolverSkipKpoints',  eigens%skip_finite_weight_kpoints)

    ! set KS object
    eigens%xc => xc

    POP_SUB(eigensolver_init)
  end subroutine eigensolver_init


  ! ---------------------------------------------------------
  subroutine eigensolver_end(eigens)
    type(eigensolver_t), intent(inout) :: eigens

    PUSH_SUB(eigensolver_end)

    select case(eigens%es_type)
    case(RS_PLAN, RS_CG, RS_LOBPCG, RS_RMMDIIS, RS_PSD)
      call preconditioner_end(eigens%pre)
    end select

    SAFE_DEALLOCATE_P(eigens%converged)
    SAFE_DEALLOCATE_P(eigens%diff)

    POP_SUB(eigensolver_end)
  end subroutine eigensolver_end


  ! ---------------------------------------------------------
  subroutine eigensolver_run(eigens, gr, st, hm, iter, conv, nstconv)
    type(eigensolver_t),  intent(inout) :: eigens
    type(grid_t),         intent(in)    :: gr
    type(states_t),       intent(inout) :: st
    type(hamiltonian_t),  intent(inout) :: hm
    integer,              intent(in)    :: iter
    logical,    optional, intent(out)   :: conv
    integer,    optional, intent(in)    :: nstconv !< Number of states considered for 
                                                   !< the convergence criteria

    integer :: maxiter, ik, ist, nstconv_
#ifdef HAVE_MPI
    logical :: conv_reduced
    integer :: outcount, lmatvec
    FLOAT, allocatable :: ldiff(:), leigenval(:)
    integer, allocatable :: lconv(:)
#endif
    type(profile_t), save :: prof

    call profiling_in(prof, "EIGEN_SOLVER")
    PUSH_SUB(eigensolver_run)

    if(present(conv)) conv = .false.
    if(present(nstconv)) then 
      nstconv_ = nstconv
    else
      nstconv_ = st%nst
    end if

    eigens%matvec = 0

    if(mpi_grp_is_root(mpi_world) .and. eigensolver_has_progress_bar(eigens) .and. .not. debug%info) then
      call loct_progress_bar(-1, st%lnst*st%d%kpt%nlocal)
    end if

    ik_loop: do ik = st%d%kpt%start, st%d%kpt%end
     if(eigens%skip_finite_weight_kpoints.and. st%d%kweights(ik) > M_ZERO) cycle
      maxiter = eigens%es_maxiter

      if(st%calc_eigenval) then
        if(eigens%es_type == RS_RMMDIIS .or. eigens%es_type == RS_PSD &
          .or. (eigens%converged(ik) == 0 .and. hm%theory_level /= INDEPENDENT_PARTICLES)) then
          
          if (states_are_real(st)) then
            call dsubspace_diag(eigens%sdiag, gr%der, st, hm, ik, st%eigenval(:, ik), eigens%diff(:, ik))
          else
            call zsubspace_diag(eigens%sdiag, gr%der, st, hm, ik, st%eigenval(:, ik), eigens%diff(:, ik))
          end if
        end if
      end if

      if (states_are_real(st)) then

        select case(eigens%es_type)
        case(RS_CG_NEW)
          call deigensolver_cg2_new(gr, st, hm, eigens%tolerance, maxiter, eigens%converged(ik), ik, eigens%diff(:, ik))
        case(RS_CG)
          call deigensolver_cg2(gr, st, hm, eigens%xc, eigens%pre, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik), &
            orthogonalize_to_all=eigens%orthogonalize_to_all, &
            conjugate_direction=eigens%conjugate_direction, &
            additional_terms=eigens%additional_terms)
        case(RS_PLAN)
          call deigensolver_plan(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, eigens%converged(ik), ik, eigens%diff(:, ik))
        case(RS_EVO)
          call deigensolver_evolution(gr, st, hm, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik), tau = eigens%imag_time)
        case(RS_LOBPCG)
          call deigensolver_lobpcg(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik), hm%d%block_size)
        case(RS_RMMDIIS)
          if(iter <= eigens%rmmdiis_minimization_iter) then
            maxiter = 2
            call deigensolver_rmmdiis_min(gr, st, hm, eigens%pre, maxiter, eigens%converged(ik), ik)
          else
            call deigensolver_rmmdiis(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, &
              eigens%converged(ik), ik, eigens%diff(:, ik))
          end if
        case(RS_PSD)
          call deigensolver_rmmdiis_min(gr, st, hm, eigens%pre, maxiter, eigens%converged(ik), ik)
        end select

        ! FEAST: subspace diag or not?
        if(st%calc_eigenval) then
          if(eigens%es_type /= RS_RMMDIIS .and. eigens%es_type /= RS_PSD) then
            call dsubspace_diag(eigens%sdiag, gr%der, st, hm, ik, st%eigenval(:, ik), eigens%diff(:, ik))
          end if
        end if
        
      else

        select case(eigens%es_type)
        case(RS_CG_NEW)
          call zeigensolver_cg2_new(gr, st, hm, eigens%tolerance, maxiter, eigens%converged(ik), ik, eigens%diff(:, ik))
        case(RS_CG)
           if(eigens%folded_spectrum) then
             call zeigensolver_cg2(gr, st, hm, eigens%xc, eigens%pre, eigens%tolerance, maxiter, eigens%converged(ik), ik, & 
                                eigens%diff(:, ik), shift=eigens%spectrum_shift, &
                                orthogonalize_to_all=eigens%orthogonalize_to_all, &
                                conjugate_direction=eigens%conjugate_direction, &
                                additional_terms=eigens%additional_terms)

           else
              call zeigensolver_cg2(gr, st, hm, eigens%xc, eigens%pre, eigens%tolerance, maxiter, eigens%converged(ik), ik, &
                                eigens%diff(:, ik), &
                                orthogonalize_to_all=eigens%orthogonalize_to_all, &
                                conjugate_direction=eigens%conjugate_direction, &
                                additional_terms=eigens%additional_terms)

           end if
        case(RS_PLAN)
          call zeigensolver_plan(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik))
        case(RS_EVO)
          call zeigensolver_evolution(gr, st, hm, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik), tau = eigens%imag_time)
        case(RS_LOBPCG)
          call zeigensolver_lobpcg(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, &
            eigens%converged(ik), ik, eigens%diff(:, ik), hm%d%block_size)
        case(RS_RMMDIIS)
          if(iter <= eigens%rmmdiis_minimization_iter) then
            maxiter = 2
            call zeigensolver_rmmdiis_min(gr, st, hm, eigens%pre, maxiter, eigens%converged(ik), ik)
          else
            call zeigensolver_rmmdiis(gr, st, hm, eigens%pre, eigens%tolerance, maxiter, &
              eigens%converged(ik), ik,  eigens%diff(:, ik))
          end if
        case(RS_PSD)
          call zeigensolver_rmmdiis_min(gr, st, hm, eigens%pre, maxiter, eigens%converged(ik), ik)
        end select

        if(st%calc_eigenval) then
          if(eigens%es_type /= RS_RMMDIIS .and. eigens%es_type /= RS_PSD) then
            call zsubspace_diag(eigens%sdiag, gr%der, st, hm, ik, st%eigenval(:, ik), eigens%diff(:, ik))
          end if
        end if
        
      end if

      if(st%calc_eigenval .and. .not. eigens%folded_spectrum) then
        ! recheck convergence after subspace diagonalization, since states may have reordered
        eigens%converged(ik) = 0
        do ist = 1, st%nst
          if(eigens%diff(ist, ik) < eigens%tolerance) then
            eigens%converged(ik) = ist
          else
            exit
          end if
        end do
      end if
      
      eigens%matvec = eigens%matvec + maxiter
    end do ik_loop

    if(mpi_grp_is_root(mpi_world) .and. eigensolver_has_progress_bar(eigens) .and. .not. debug%info) then
      write(stdout, '(1x)')
    end if

    if(present(conv)) conv = all(eigens%converged(st%d%kpt%start:st%d%kpt%end) >= nstconv_)

#ifdef HAVE_MPI
    if(st%d%kpt%parallel) then
      if(present(conv)) then
        call MPI_Allreduce(conv, conv_reduced, 1, MPI_LOGICAL, MPI_LAND, st%d%kpt%mpi_grp%comm, mpi_err)
        conv = conv_reduced
      end if

      lmatvec = eigens%matvec
      call MPI_Allreduce(lmatvec, eigens%matvec, 1, MPI_INTEGER, MPI_SUM, st%d%kpt%mpi_grp%comm, mpi_err)

      SAFE_ALLOCATE(lconv(1:st%d%kpt%nlocal))
      lconv(1:st%d%kpt%nlocal) = eigens%converged(st%d%kpt%start:st%d%kpt%end)
      call lmpi_gen_allgatherv(st%d%kpt%nlocal, lconv, outcount, eigens%converged, st%d%kpt%mpi_grp)
      ASSERT(outcount == st%d%nik)
      SAFE_DEALLOCATE_A(lconv)

      ! every node needs to know all eigenvalues (and diff)
      SAFE_ALLOCATE(ldiff(1:st%d%kpt%nlocal))
      SAFE_ALLOCATE(leigenval(1:st%d%kpt%nlocal))
      do ist = st%st_start, st%st_end
        ldiff(1:st%d%kpt%nlocal) = eigens%diff(ist, st%d%kpt%start:st%d%kpt%end)
        leigenval(1:st%d%kpt%nlocal) = st%eigenval(ist, st%d%kpt%start:st%d%kpt%end)
        call lmpi_gen_allgatherv(st%d%kpt%nlocal, ldiff, outcount, &
          eigens%diff(ist, :), st%d%kpt%mpi_grp)
        ASSERT(outcount == st%d%nik)
        call lmpi_gen_allgatherv(st%d%kpt%nlocal, leigenval, outcount, &
          st%eigenval(ist, :), st%d%kpt%mpi_grp)
        ASSERT(outcount == st%d%nik)
      end do
      SAFE_DEALLOCATE_A(ldiff)
      SAFE_DEALLOCATE_A(leigenval)
    end if
#endif

    POP_SUB(eigensolver_run)
    call profiling_out(prof)
  end subroutine eigensolver_run


  ! ---------------------------------------------------------
  logical function eigensolver_parallel_in_states(this) result(par_stat)
    type(eigensolver_t), intent(in) :: this

    PUSH_SUB(eigensolver_parallel_in_states)

    par_stat = .false.

    select case(this%es_type)
    case(RS_RMMDIIS, RS_LOBPCG, RS_PSD)
      par_stat = .true.
    end select

    POP_SUB(eigensolver_parallel_in_states)
  end function eigensolver_parallel_in_states


  ! ---------------------------------------------------------
  logical function eigensolver_has_progress_bar(this) result(has)
    type(eigensolver_t), intent(in) :: this

    PUSH_SUB(eigensolver_has_progress_bar)

    has = .false.

    select case(this%es_type)
    case(RS_RMMDIIS, RS_CG, RS_CG_NEW, RS_LOBPCG)
      has = .true.
    end select

    POP_SUB(eigensolver_has_progress_bar)
  end function eigensolver_has_progress_bar

#include "undef.F90"
#include "real.F90"
#include "eigen_plan_inc.F90"
#include "eigen_evolution_inc.F90"

#include "undef.F90"
#include "complex.F90"
#include "eigen_plan_inc.F90"
#include "eigen_evolution_inc.F90"

end module eigensolver_oct_m


!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
