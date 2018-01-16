!> @file
!!  Define function evaluations and features
!! @author
!!    Copyright (C) 2015-2015 BigDFT group
!!    This file is distributed under the terms of the
!!    GNU General Public License, see ~/COPYING file
!!    or http://www.gnu.org/copyleft/gpl.txt .
!!    For the list of contributors, see ~/AUTHORS
module f_functions
  use f_precisions
  use f_enums
  use numerics, only: pi,safe_erf,safe_exp
  implicit none
  private

  integer, parameter :: MAX_FUNC_PARAMETERS=2

  integer, parameter :: FUNCTION_NULL=0

  integer, parameter :: PREFACTOR_=1
  integer, parameter :: SCALE_=1
  integer, parameter :: EXPONENT_=1
  integer, parameter :: LENGTH_=1
  integer, parameter :: FREQUENCY_=2 !et cetera

  integer, parameter :: FUNC_CONSTANT = 1
  integer, parameter :: FUNC_GAUSSIAN = 2
  integer, parameter :: FUNC_GAUSSIAN_SHRINKED = 3
  integer, parameter :: FUNC_COSINE = 4
  integer, parameter :: FUNC_EXP_COSINE = 5
  integer, parameter :: FUNC_SHRINK_GAUSSIAN = 6
  integer, parameter :: FUNC_SINE = 7
  integer, parameter :: FUNC_ATAN = 8
  integer, parameter :: FUNC_ERF = 9

  type(f_enumerator), public :: f_constant=f_enumerator('CONSTANT',FUNC_CONSTANT,null())
  type(f_enumerator), public :: f_gaussian=f_enumerator('GAUSSIAN',FUNC_GAUSSIAN,null())
  type(f_enumerator), public :: f_gaussian_shrinked=f_enumerator('GAUSSIAN_SHRINKED',FUNC_GAUSSIAN_SHRINKED,null())
  type(f_enumerator), public :: f_cosine=f_enumerator('COSINE',FUNC_COSINE,null())
  type(f_enumerator), public :: f_exp_cosine=f_enumerator('EXP_COSINE',FUNC_EXP_COSINE,null())
  type(f_enumerator), public :: f_shrink_gaussian=f_enumerator('SHRINK_GAUSSIAN',FUNC_SHRINK_GAUSSIAN,null())
  type(f_enumerator), public :: f_sine=f_enumerator('SINE',FUNC_SINE,null())
  type(f_enumerator), public :: f_atan=f_enumerator('ATAN',FUNC_ATAN,null())
  type(f_enumerator), public :: f_erf=f_enumerator('ERF',FUNC_ERF,null())
  type(f_enumerator) :: ENUM_1D_GRID=f_enumerator('1D_GRID',-1,null())


  type, public :: f_function
     integer :: function_type
     !>parameter of the function that has to be defined
     real(f_double), dimension(MAX_FUNC_PARAMETERS) :: params
     !type(kernel_ctx) :: func !<for more elaborate evaluations
     real(f_double), pointer :: argument
     type(f_function), pointer :: compose
     type(f_function), pointer :: multiply
     type(f_function), pointer :: add
  end type f_function

  type, public :: f_grid
     type(f_enumerator) :: fmt
     integer :: npts=0
     real(f_double) :: h=0.0_f_double
     real(f_double) :: c=0.0_f_double
  end type f_grid

  public :: f_function_new,eval,diff
  public :: separable_3d_function,separable_3d_laplacian,radial_3d_function

  contains

!!$    !composition
!!$    func=f_function('gaussian',compose=f_function('tan'))
!!$    func2=func*f_function('gaussian',exponent=12.0)

    pure function f_function_null() result(f)
      use f_utils, only: f_zero
      implicit none
      type(f_function) :: f
      f%function_type=FUNCTION_NULL
      f%params=0.0_f_double
      nullify(f%argument)
      nullify(f%compose)
      nullify(f%multiply)
      nullify(f%add)
    end function f_function_null

    function f_function_new(function_type,exponent,length,frequency,scale,prefactor)
      use f_enums
      use dictionaries, only: f_err_raise
      implicit none
      type(f_enumerator), intent(in) :: function_type
      real(f_double), intent(in), optional :: exponent,length,frequency,scale,prefactor
      type(f_function) :: f_function_new
      !local variables

      f_function_new=f_function_null()
      !check on arguments
      f_function_new%function_type=toi(function_type)
      select case(f_function_new%function_type)
      case(FUNC_CONSTANT)
         if (f_err_raise(.not. present(prefactor),'f_function: prefactor')) return
         f_function_new%params(PREFACTOR_)=prefactor
      case(FUNC_GAUSSIAN)
         if (f_err_raise(.not. present(exponent),'f_function: exponent')) return
         f_function_new%params(EXPONENT_)=exponent
      case(FUNC_GAUSSIAN_SHRINKED,FUNC_SHRINK_GAUSSIAN)
         if (f_err_raise(.not. present(length),'f_function: length')) return
         f_function_new%params(LENGTH_)=length
      case(FUNC_COSINE,FUNC_EXP_COSINE,FUNC_SINE)
         if (f_err_raise(.not. present(length),'f_function: length')) return
         if (f_err_raise(.not. present(frequency),'f_function: frequency')) return
         f_function_new%params(LENGTH_)=length
         f_function_new%params(FREQUENCY_)=frequency
      case(FUNC_ATAN,FUNC_ERF)
         if (f_err_raise(.not. present(scale),'f_function: scale')) return
         f_function_new%params(SCALE_)=scale
      end select
    end function f_function_new

    pure function eval(func,x) result(y)
      implicit none
      type(f_function), intent(in) :: func
      real(f_double), intent(in) :: x
      real(f_double) :: y
      !local variables
      integer, parameter :: idiff=0
      
      select case(func%function_type)
      case(FUNC_CONSTANT)
         y=func%params(PREFACTOR_)
      case(FUNC_GAUSSIAN)
         y=gaussian(func%params(EXPONENT_),x,idiff)
      case(FUNC_GAUSSIAN_SHRINKED)
         y=gaussian_shrinked(func%params(LENGTH_),x,idiff)
      case(FUNC_COSINE)
         y=cosine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_EXP_COSINE)
         y=exp_cosine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_SHRINK_GAUSSIAN)
         y=shrinked_gaussian(func%params(LENGTH_),x,idiff)
      case(FUNC_SINE)
         y=sine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_ATAN)
         y=arctan(1.0_f_double/func%params(SCALE_),x,idiff)
      case(FUNC_ERF)
         y=error_function(func%params(SCALE_),x,idiff)
      case default
         y=0.0_f_double
      end select
    end function eval

    pure function diff(func,x,order) result(y)
      implicit none
      type(f_function), intent(in) :: func
      real(f_double), intent(in) :: x
      integer, intent(in), optional :: order
      real(f_double) :: y
      !local variables
      integer :: idiff
      
      idiff=1
      if (present(order)) idiff=order

      select case(func%function_type)
      case default !(FUNC_CONSTANT)
         y=0.0_f_double
      case(FUNC_GAUSSIAN)
         y=gaussian(func%params(EXPONENT_),x,idiff)
      case(FUNC_GAUSSIAN_SHRINKED)
         y=gaussian_shrinked(func%params(LENGTH_),x,idiff)
      case(FUNC_COSINE)
         y=cosine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_EXP_COSINE)
         y=exp_cosine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_SHRINK_GAUSSIAN)
         y=shrinked_gaussian(func%params(LENGTH_),x,idiff)
      case(FUNC_SINE)
         y=sine(func%params(LENGTH_),func%params(FREQUENCY_),x,idiff)
      case(FUNC_ATAN)
         y=arctan(1.0_f_double/func%params(SCALE_),x,idiff)
      case(FUNC_ERF)
         y=error_function(func%params(SCALE_),x,idiff)
      end select
    end function diff

    pure function grid_1d_new(npts,h,x0,centered) result(g)
      implicit none
      integer, intent(in) :: npts
      real(f_double), intent(in) :: h
      logical, intent(in), optional :: centered
      real(f_double), intent(in), optional :: x0
      type(f_grid) :: g
      !local variables
      !g%fmt=enum_1d_grid
      g%npts=npts
      g%h=h
      g%c=0.0_f_double
      if (present(centered)) then
         if (centered) g%c=real(npts/2-1,f_double)
      else if (present(x0)) then
         g%c=x0
      end if
    end function grid_1d_new

    pure function grid_x(g,i) result(x)
      implicit none
      type(f_grid), intent(in) :: g
      integer, intent(in) :: i
      real(f_double) :: x
      
      !for the moment only 1d grid, but also radial grid might be generalized
      x=g%h*(real(i,f_double)-g%c)
    end function grid_x

    !>dump the function and its first derivative in the unit specified
    subroutine f_function_dump(unit,func,grid)
      implicit none
      integer, intent(in) :: unit
      type(f_function), intent(in) :: func
      type(f_grid), intent(in) :: grid
      !local variables
      integer :: i
      real(f_double) :: fx,fx1,fx2,x      
      do i=1,grid%npts
         x=grid_x(grid,i)
         fx=eval(func,x)
         fx1=diff(func,x)
         fx2=diff(func,x,order=2)
         write(unit,'(1x,I8,4(1x,e22.15))') i,x,fx,fx1,fx2
      end do
    end subroutine f_function_dump

    pure function gaussian(a,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff 
      real(f_double), intent(in) :: a,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r2
      r2=a*x**2
      f=safe_exp(-r2) !<checked
      select case(idiff)
      case(1)
         f=-2.0_f_double*a*x*f !<checked
      case(2)
         f=(-2.0_f_double*a+4.0_f_double*a*r2)*f !<checked
      end select
    end function gaussian

    pure function gaussian_shrinked(length,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff 
      real(f_double), intent(in) :: length,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r,y

      r=pi*x/length
      y=tan(r)
      f=safe_exp(-y**2) !<checked
      select case(idiff)
      case(1)
         f=-2.d0*pi*f*y/(length*cos(r)**2) !<checked
      case(2)
         f=2.d0*pi**2*(2.d0*y**6+y**4-2.d0*y**2-1.d0)/length**2*f !<checked
      end select
    end function gaussian_shrinked

    pure function cosine(length,frequency,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff 
      real(f_double), intent(in) :: length,frequency,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r

      r=frequency*pi*x/length
      select case(idiff)
      case(0)
         f=cos(r) !<checked
      case(1)
         f=-dsin(r)*frequency*pi/length !<checked
      case(2)
         f=-(frequency*pi/length)**2*cos(r) !<checked
      case default
         f=0.0_f_double
      end select
    end function cosine

    pure function exp_cosine(a,nu,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff 
      real(f_double), intent(in) :: a,nu,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r,y,yp,factor

      r=pi*nu/a*x
      y=cos(r)
      f=safe_exp(y) !<checked 
      select case(idiff)
      case(1)
         yp=-sin(r)
         f=f*pi*nu/a*yp !<checked
      case(2)
         yp=sin(r)
         factor=(pi*nu/a)**2*(-y+yp**2)
         f= factor*f !<checked
      end select
    end function exp_cosine

    !>not to be confused with gaussian_shrinked
    pure function shrinked_gaussian(length,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff 
      real(f_double), intent(in) :: length,x
      real(f_double) :: f
      !local variables
      real(f_double) :: g,h,g1,h1,h2,g2,a

      a=50.0_f_double/length**2
      g=gaussian_shrinked(length,x,0)
      h=gaussian(a,x,0)
      select case(idiff)
      case(0)
         f=g*h !<checked
      case(1)
         g1=gaussian_shrinked(length,x,1)
         h1=gaussian(a,x,1)
         f=g1*h+g*h1 !<checked
      case(2)
         g1=gaussian_shrinked(length,x,1)
         h1=gaussian(a,x,1)
         g2=gaussian_shrinked(length,x,2)
         h2=gaussian(a,x,2)
         f=g2*h+g*h2+2.0_f_double*g1*h1 !<checked
      case default
         f=0.0_f_double
      end select
    end function shrinked_gaussian

    pure function sine(length,frequency,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff
      real(f_double), intent(in) :: length,frequency,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r

      r=frequency*pi*x/length
      select case(idiff)
      case(0)
         f=sin(r) !<checked
      case(1)
         f=frequency*pi*cos(r)/length !<checked
      case(2)
         f=-(frequency*pi/length)**2*sin(r) !<checked
      case default
         f=0.0_f_double
      end select
    end function sine

    pure function arctan(a,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff
      real(f_double), intent(in) :: a,x
      real(f_double) :: f
      !local variables
      real(f_double) :: r,factor

      r=a*x
      select case(idiff)
      case(0)
         f=atan(r) !<checked
      case(1)
         factor=r**2+1.d0
         f=a/factor !<checked
      case(2)
         factor=r**2+1.d0
         f=-2.d0*r*a**2/factor**2 !<checked
      case default
         f=0.0_f_double
      end select
    end function arctan

    pure function error_function(a,x,idiff) result(f)
      implicit none
      integer, intent(in) :: idiff
      real(f_double), intent(in) :: a,x
      real(f_double) :: f
      !local variables
      real(f_double) :: factor,y,g,h

      factor=sqrt(2.d0/pi)/a
      if (abs(x)<=1.e-15_f_double) then
         select case(idiff)
         case(0)
            f=factor
         case default !also 1
            f=0.0_f_double
         case(2)
            f=-sqrt(2.d0/pi)/(3.d0*a**3) !<checked
         end select
      else
         y=x/(sqrt(2.d0)*a)
         f=safe_erf(y)/x
         select case(idiff)
         case(1)
            y=x*x
            y=y/(2.d0*a**2)
            g=safe_exp(-y)
            h=1.d0/a**2+2.d0/x**2
            f=-f/x+factor*g/x !<checked
         case(2)
            y=x*x
            y=y/(2.d0*a**2)
            g=safe_exp(-y)
            h=1.d0/a**2+2.d0/x**2
            f=-factor*g*h+2.d0*f/x**2  !<checked
         end select
      end if
    end function error_function

    subroutine radial_3d_function(bit,func,factor,f)
      use box
      implicit none
      real(f_double), intent(in) :: factor
      type(box_iterator), intent(inout) :: bit
      type(f_function), intent(in) :: func
      real(f_double), dimension(bit%mesh%ndims(1),bit%mesh%ndims(2),bit%mesh%ndims(3)), intent(out) :: f
      !local variables
      real(f_double) :: r2,r

      do while(box_next_point(bit))
         r2=square(bit%mesh,bit%rxyz)
         r = sqrt(r2)
         f(bit%i,bit%j,bit%k) =factor*eval(func,r)
      end do

    end subroutine radial_3d_function

    !> fill a function and its laplacian
    subroutine separable_3d_function(bit,funcs,factor,f)
      use box
      implicit none
      real(f_double), intent(in) :: factor
      type(box_iterator), intent(inout) :: bit
      type(f_function), dimension(3), intent(in) :: funcs
      real(f_double), dimension(bit%mesh%ndims(1),bit%mesh%ndims(2),bit%mesh%ndims(3)), intent(out) :: f
      !local variables
      real(f_double) :: fx,fy,fz

      do while(box_next_z(bit))
         fz=eval(funcs(3),bit%rxyz(3))
         do while(box_next_y(bit))
            fy=eval(funcs(2),bit%rxyz(2))
            do while(box_next_x(bit))
               fx=eval(funcs(1),bit%rxyz(1))
               f(bit%i,bit%j,bit%k) = factor*fx*fy*fz
            end do
         end do
      end do
    end subroutine separable_3d_function

    !> fill a function and its laplacian
    subroutine separable_3d_laplacian(bit,funcs,factor,f)
      use box
      implicit none
      real(f_double), intent(in) :: factor
      type(box_iterator), intent(inout) :: bit
      type(f_function), dimension(3), intent(in) :: funcs
      real(f_double), dimension(bit%mesh%ndims(1),bit%mesh%ndims(2),bit%mesh%ndims(3)), intent(out) :: f
      !local variables
      real(f_double) :: fx,fy,fz,fx1,fx2,fy1,fy2,fz1,fz2

      if (.not. bit%mesh%orthorhombic) then
         do while(box_next_z(bit))
            fz=eval(funcs(3),bit%rxyz(3))
            fz1=diff(funcs(3),bit%rxyz(3))
            fz2=diff(funcs(3),bit%rxyz(3),order=2)
            do while(box_next_y(bit))
               fy=eval(funcs(2),bit%rxyz(2))
               fy1=diff(funcs(2),bit%rxyz(2))
               fy2=diff(funcs(2),bit%rxyz(2),order=2)
               do while(box_next_x(bit))
                  fx=eval(funcs(1),bit%rxyz(1))
                  fx1=diff(funcs(1),bit%rxyz(1))
                  fx2=diff(funcs(1),bit%rxyz(1),order=2)
                  f(bit%i,bit%j,bit%k) = factor*((bit%mesh%gu(1,1)*fx2*fy*fz+bit%mesh%gu(2,2)*fx*fy2*fz+&
                       bit%mesh%gu(3,3)*fx*fy*fz2)+&
                       2.0_f_double*(bit%mesh%gu(1,2)*fx1*fy1*fz+bit%mesh%gu(1,3)*fx1*fy*fz1+bit%mesh%gu(2,3)*fx*fy1*fz1))
               end do
            end do
         end do
      else
         do while(box_next_z(bit))
            fz=eval(funcs(3),bit%rxyz(3))
            fz2=diff(funcs(3),bit%rxyz(3),order=2)
            !print *,'z',bit%k,fz,fz2
            do while(box_next_y(bit))
               fy=eval(funcs(2),bit%rxyz(2))
               fy2=diff(funcs(2),bit%rxyz(2),order=2)
               !print *,'y',bit%j,fy,fy2
               do while(box_next_x(bit))
                  fx=eval(funcs(1),bit%rxyz(1))
                  fx2=diff(funcs(1),bit%rxyz(1),order=2)
                  !print *,'x',bit%i,fx,fx2
                  f(bit%i,bit%j,bit%k) = factor*(fx2*fy*fz+fx*fy2*fz+fx*fy*fz2)
               end do
            end do
         end do
      end if
    end subroutine separable_3d_laplacian

end module f_functions
