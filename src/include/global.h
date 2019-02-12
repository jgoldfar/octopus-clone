!! Copyright (C) 2003-2006 M. Marques, A. Castro, A. Rubio, G. Bertsch
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

#include "config_F90.h"
#include "options.h"  
#include "defaults.h"
  
! If the compiler accepts long Fortran lines, it is better to use that
! capacity, and build all the preprocessor definitions in one line. In
! this way, the debuggers will provide the right line numbers.
#if defined(LONG_LINES)
#  define _newline_
#  define _anl_
#else
#  define _newline_ \newline
#  define _anl_ & \newline
#endif


! If the compiler accepts line number markers, then "CARDINAL" and "ACARDINAL"
! will put them.  Otherwise, just a new line or a ampersand plus a new line.
! These macros should be used in macros that span several lines. They should by
! put immedialty before a line where a compilation error might occur and at the
! end of the macro.
! Note that the "cardinal" and "newline" words are substituted by the program
! preprocess.pl by the ampersand and by a real new line just before compilation.
#if defined(LONG_LINES)
#  define CARDINAL
#  define ACARDINAL
#else
#  if defined(F90_ACCEPTS_LINE_NUMBERS)
#    define CARDINAL _newline_\cardinal __LINE__ __FILE__ _newline_
#    define ACARDINAL _anl_\cardinal __LINE__ __FILE__ _newline_
#  else
#    define CARDINAL _newline_
#    define ACARDINAL _anl_
#  endif
#endif


! The assertions are ignored if the code is compiled in not-debug mode (NDEBUG
! is defined). Otherwise it is merely a logical assertion that, when fails,
! prints out the assertion string, the file, and the line. The subroutine
! assert_die is in the global_m module.
#if !defined(NDEBUG)
#  define ASSERT(expr)  \
  if(.not.(expr)) _anl_ \
     call assert_die(TOSTRING(expr), _anl_ __FILE__, _anl_  __LINE__) \
  CARDINAL
#else
#  define ASSERT(expr)
#endif


! Some compilers will not have the sizeof intrinsic.
#ifdef HAVE_FC_SIZEOF
#  define SIZEOF(x) sizeof(x)
#else
#  define SIZEOF(x) 1
#endif


! In octopus, one should normally use the SAFE_(DE)ALLOCATE macros below, which emit
! a helpful error if the the allocation or deallocation fails. The "MY_DEALLOCATE" macro
! is only used in this file; in the code, one should use SAFE_DEALLOCATE_P for pointers
! and SAFE_DEALLOCATE_A for arrays.
#if defined(NDEBUG)
#  define SAFE_ALLOCATE(x) allocate(x)

#  define SAFE_DEALLOCATE_P(x) \
  if(associated(x)) then; CARDINAL \
    deallocate(x);        CARDINAL \
    nullify(x);           _newline_ \
  end if; \
  CARDINAL
#  define SAFE_DEALLOCATE_A(x) \
  if(allocated(x)) then; CARDINAL \
    deallocate(x);       _newline_ \
  end if; \
  CARDINAL

#else
#  define SAFE_ALLOCATE(x)			\
  allocate( ACARDINAL x, _anl_ stat=global_alloc_err); \
  if(not_in_openmp() .and. iand(prof_vars%mode, PROFILING_MEMORY).ne.0 .or. global_alloc_err.ne.0) _anl_ \
  global_sizeof = SIZEOF( ACARDINAL x _anl_ ); \
  if(iand(prof_vars%mode, PROFILING_MEMORY).ne.0) _anl_ \
    call profiling_memory_allocate(_anl_ TOSTRING(x), _anl_ __FILE__, _anl_ __LINE__, _anl_ global_sizeof); _newline_ \
  if(global_alloc_err.ne.0) _anl_ \
    call alloc_error(global_sizeof, _anl_ __FILE__, _anl_ __LINE__); \
  CARDINAL

#  define MY_DEALLOCATE(x) \
  global_sizeof = SIZEOF(x); \
  CARDINAL \
  deallocate(x, stat=global_alloc_err); _newline_ \
  if(not_in_openmp() .and. iand(prof_vars%mode, PROFILING_MEMORY).ne.0) _anl_ \
    call profiling_memory_deallocate(TOSTRING(x), _anl_ __FILE__, _anl_ __LINE__, _anl_ global_sizeof); _newline_ \
  if(global_alloc_err.ne.0) _anl_ \
    call dealloc_error(global_sizeof, _anl_ __FILE__, _anl_ __LINE__)

#  define SAFE_DEALLOCATE_P(x) \
  if(associated(x)) then; _newline_ \
    MY_DEALLOCATE(x);     _newline_ \
    nullify(x);           _newline_ \
  end if; \
  CARDINAL

#  define SAFE_DEALLOCATE_A(x) \
  if(allocated(x)) then;  _newline_ \
    MY_DEALLOCATE(x);     _newline_ \
  end if; \
  CARDINAL

#endif


! This was used in the past and should not be used any more.
#define ALLOCATE(a,b) _DEPRECATED_PLEASE_USE_SAFE_ALLOCATE_


! The following macros facilitate the use of real or complex variables,
! and the possibility of compiling the code in single or double precision.
#define REAL_DOUBLE real(8)
#define REAL_SINGLE real(4)

#define REAL_PRECISION 8
#define FLOAT          real(8)
#define MPI_FLOAT 	 MPI_DOUBLE_PRECISION
#define MPI_2FLOAT     MPI_2DOUBLE_PRECISION
#define CMPLX     	 complex(8)
#define MPI_CMPLX 	 MPI_DOUBLE_COMPLEX
#define PREC(x)   	 d ## x
#define ZPREC(x)   	 z ## x
#define CNST(x)   	 x ## _8
#define XC_F90(x)      xc_f90_ ## x

#define   TOFLOAT(x) real(x, REAL_PRECISION)
#define   TOCMPLX(x, y) cmplx(x, y, REAL_PRECISION)

! The MPI1 and MPI2 standards are different regarding the MPI_IN_PLACE constant. In
! the code, just use the MPI_IN_PLACE_OR defined here.
#ifdef HAVE_MPI
#ifdef HAVE_MPI2
#define MPI_IN_PLACE_OR(x) MPI_IN_PLACE
#else
#define MPI_IN_PLACE_OR(x) x
#endif
#endif


! the TOSTRING macro converts a macro into a string
! do not use the STRINGIFY macro
#define STRINGIFY(x) #x
#define TOSTRING(x)  STRINGIFY(x)
#define INCR(x, y) x = (x) + (y)


! Whenever a procedure is not called too many times, one should start it
! and finish it with the PUSH_SUB and POP_SUB macros, which are these
! pieces of code that call the push_sub and pop_sub routines defined
! in the messages_m module.
#define PUSH_SUB(routine) \
  if(debug%trace) then; _newline_ \
    if(not_in_openmp()) then; _newline_ \
      call push_sub(__FILE__+"." _anl_ +TOSTRING(routine)); _newline_ \
    endif; _newline_ \
  endif; \
  CARDINAL
#define POP_SUB(routine) \
  if(debug%trace) then; _newline_ \
    if(not_in_openmp()) then; _newline_ \
      call pop_sub(__FILE__+"." _anl_ +TOSTRING(routine)); _newline_ \
    endif; _newline_ \
  endif; \
  CARDINAL

! the leading dimension of the array
#define LD(a) ubound(a,dim=1)

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
