!> @file
!!   Filters for interpolating scaling functions (order 30)
!! @author
!!    Copyright (C) 2009-2011 BigDFT group 
!!    This file is distributed under the terms of the
!!    GNU General Public License, see ~/COPYING file
!!    or http://www.gnu.org/copyleft/gpl.txt .
!!    For the list of contributors, see ~/AUTHORS 
integer, parameter :: m=32
real(kind=8), dimension(-m:m) :: ch = (/ &
     0.d0, 0.d0, 0.d0, &
     2.78364831185484718d-10,0.d0,-8.6705490009997277d-9,0.d0, &
     1.31098700895115883d-7,0.d0,-1.28248729136526407d-6,0.d0, &
     9.13008809805271326d-6,0.d0,-0.000050455750015554468d0,0.d0, &
     0.000225566882422478798d0,0.d0,-0.00083996810502084962d0,0.d0, &
     0.0026652834101623113d0,0.d0,-0.00734972091893243418d0,0.d0, &
     0.0179659844685015058d0,0.d0,-0.039898484988490357d0,0.d0, &
     0.0837868184758297496d0,0.d0,-0.18261229667809048d0,0.d0,0.626099302896310217d0, &
     1.d0,0.626099302896310217d0,0.d0,-0.18261229667809048d0,0.d0, &
     0.0837868184758297496d0,0.d0,-0.039898484988490357d0,0.d0, &
     0.0179659844685015058d0,0.d0,-0.00734972091893243418d0,0.d0, &
     0.0026652834101623113d0,0.d0,-0.00083996810502084962d0,0.d0, &
     0.000225566882422478798d0,0.d0,-0.000050455750015554468d0,0.d0, &
     9.13008809805271326d-6,0.d0,-1.28248729136526407d-6,0.d0, &
     1.31098700895115883d-7,0.d0,-8.6705490009997277d-9,0.d0, &
     2.78364831185484718d-10, &
     0.d0, 0.d0, 0.d0   /)
real(kind=8), dimension(-m:m) ::  cg,cht,cgt

!******** coefficients for wavelet transform *********************
do i=-m,m
   cht(i)=0.d0
   cg(i)=0.d0
   cgt(i)=0.d0
enddo

! the normalization is chosen such that a constant function remains the same constant 
! on each level of the transform

cht( 0)=1.d0

! g coefficients from h coefficients
do i=-m,m-1
   cg(i+1)=cht(-i)*(-1.d0)**(i+1)
   cgt(i+1)=ch(-i)*(-1.d0)**(i+1)
enddo


