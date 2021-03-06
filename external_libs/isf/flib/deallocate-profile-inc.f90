!> @file
!! Include fortran file for deallocation template
!! @author
!!    Copyright (C) 2012-2013 BigDFT group
!!    This file is distributed under the terms of the
!!    GNU General Public License, see ~/COPYING file
!!    or http://www.gnu.org/copyleft/gpl.txt .
!!    For the list of contributors, see ~/AUTHORS


 !local variables
  integer :: ierror
  ! logical :: use_global
  !$ logical :: not_omp
  !$ logical, external :: omp_in_parallel,omp_get_nested
  integer(kind=8) :: ilsize
  ! integer(kind=8) :: jlsize
  integer(kind=8) :: iadd
  ! character(len=namelen) :: array_id
  ! character(len=namelen) :: routine_id
  ! character(len=info_length) :: array_info
  ! type(dictionary), pointer :: dict_add

  if (f_err_raise(ictrl == 0,&
       'ERROR (f_free): the routine f_malloc_initialize has not been called',&
       ERR_MALLOC_INTERNAL)) return

  !$ not_omp=.not. (omp_in_parallel() .or. omp_get_nested())

  !here we should add a control of the OMP behaviour of allocation
  !in particular for what concerns the OMP nesting procedure
