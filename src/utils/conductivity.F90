!! Copyright (C) 2015 X. Andrade
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

  program conductivity
    use batch_oct_m
    use command_line_oct_m
    use geometry_oct_m
    use global_oct_m
    use grid_oct_m
    use io_oct_m
    use messages_oct_m
    use parser_oct_m
    use profiling_oct_m
    use simul_box_oct_m
    use space_oct_m
    use spectrum_oct_m
    use species_oct_m
    use states_oct_m
    use unit_oct_m
    use unit_system_oct_m

    implicit none

    integer :: iunit, ierr, ii, jj, iter, read_iter, ntime, nvel, ivel
    FLOAT, allocatable :: time(:), velocities(:, :)
    FLOAT, allocatable :: total_current(:, :), ftcurr(:, :, :), curr(:, :, :)
    FLOAT, allocatable :: heat_current(:,:), ftheatcurr(:,:,:), heatcurr(:,:,:)
    type(geometry_t)  :: geo 
    type(space_t)     :: space
    type(simul_box_t) :: sb
    type(spectrum_t) :: spectrum
    type(grid_t)     :: gr
    type(states_t)    :: st
    type(batch_t) :: currb, ftcurrb, heatcurrb, ftheatcurrb
    FLOAT :: ww, curtime, deltat, velcm(1:MAX_DIM), vel0(1:MAX_DIM), current(1:MAX_DIM), integral(1:2), v0
    integer :: ifreq, max_freq
    integer :: skip
    FLOAT, parameter :: inv_ohm_meter = CNST(4599848.1)
    logical :: from_forces
    
    
    ! Initialize stuff
    call global_init(is_serial = .true.)		 

    call getopt_init(ierr)
    call getopt_end()

    call messages_init()

    call messages_experimental('oct-conductivity')

    call io_init()

    call unit_system_init()

    call spectrum_init(spectrum, default_energy_step = CNST(0.0001), default_max_energy  = CNST(1.0))
 
    !%Variable ConductivitySpectrumTimeStepFactor
    !%Type integer
    !%Default 1
    !%Section Utilities::oct-conductivity_spectrum
    !%Description
    !% In the calculation of the conductivity, it is not necessary
    !% to read the velocity at every time step. This variable controls
    !% the integer factor between the simulation time step and the
    !% time step used to calculate the conductivity.
    !%End

    call messages_obsolete_variable('PropagationSpectrumTimeStepFactor', 'ConductivitySpectrumTimeStepFactor')
    call parse_variable('ConductivitySpectrumTimeStepFactor', 1, skip)
    if(skip <= 0) call messages_input_error('ConductivitySpectrumTimeStepFactor')

    !%Variable ConductivityFromForces
    !%Type logical
    !%Default no
    !%Section Utilities::oct-conductivity_spectrum
    !%Description
    !% (Experimental) If enabled, Octopus will attempt to calculate the conductivity from the forces instead of the current. 
    !%End
    call parse_variable('ConductivityFromForces', .false., from_forces)
    if(from_forces) call messages_experimental('ConductivityFromForces')
    
    max_freq = 1 + nint(spectrum%max_energy/spectrum%energy_step)
    
    if (spectrum%end_time < M_ZERO) spectrum%end_time = huge(spectrum%end_time)

    call space_init(space)
    call geometry_init(geo, space)
    call simul_box_init(sb, geo, space)

    call grid_init_stage_0(gr, geo, space)
    call states_init(st, gr, geo)
    
    if(from_forces) then

      call messages_write('Info: Reading coordinates from td.general/coordinates')
      call messages_info()

      ! Opens the coordinates files.
      iunit = io_open('td.general/coordinates', action='read')

      call io_skip_header(iunit)

      ntime = 1
      iter = 1

      ! check the number of time steps we will read
      do
        read(unit = iunit, iostat = ierr, fmt = *) read_iter, curtime, &
          ((geo%atom(ii)%x(jj), jj = 1, 3), ii = 1, geo%natoms), &
          ((geo%atom(ii)%v(jj), jj = 1, 3), ii = 1, geo%natoms)

        curtime = units_to_atomic(units_out%time, curtime)

        if(ierr /= 0 .or. curtime >= spectrum%end_time) then
          iter = iter - 1	! last iteration is not valid
          ntime = ntime - 1
          exit
        end if

        if(iter /= read_iter + 1) then
          call messages_write("Error while reading file 'td.general/coordinates',", new_line = .true.)
          call messages_write('expected iteration ')
          call messages_write(iter - 1)
          call messages_write(', got iteration ')
          call messages_write(read_iter)
          call messages_write('.')
          call messages_fatal()
        end if

        ! ntime counts how many steps are gonna be used
        if (curtime >= spectrum%start_time .and. mod(iter, skip) == 0) ntime = ntime + 1 

        iter = iter + 1 !counts number of timesteps (with time larger than zero up to SpecEndTime)
      end do

      call io_close(iunit)

      nvel = geo%natoms*space%dim

      SAFE_ALLOCATE(time(1:ntime))
      SAFE_ALLOCATE(velocities(1:nvel, 1:ntime))

      ! Opens the coordinates files.
      iunit = io_open('td.general/coordinates', action='read', status='old', die=.false.)

      call io_skip_header(iunit)

      ntime = 1
      iter = 1

      do
        read(unit = iunit, iostat = ierr, fmt = *) read_iter, curtime, &
          ((geo%atom(ii)%x(jj), jj = 1, 3), ii = 1, geo%natoms), &
          ((geo%atom(ii)%v(jj), jj = 1, 3), ii = 1, geo%natoms)

        curtime = units_to_atomic(units_out%time, curtime)

        if(ierr /= 0 .or. curtime >= spectrum%end_time) then
          iter = iter - 1	! last iteration is not valid
          ntime = ntime - 1
          exit
        end if

        ASSERT(iter == read_iter + 1)

        if (curtime >= spectrum%start_time .and. mod(iter, skip) == 0) then

          time(ntime) = curtime
          ivel = 1
          do ii = 1, geo%natoms
            do jj = 1, space%dim
              velocities(ivel, ntime) = units_to_atomic(units_out%velocity, geo%atom(ii)%v(jj))
              ivel = ivel + 1
            end do
          end do

          ntime = ntime + 1 
        end if

        iter = iter + 1 !counts number of timesteps (with time larger than zero up to SpecEndTime)
      end do

      call io_close(iunit)

      call messages_write('      done.')
      call messages_info()

    else !from_forces

      call messages_write('Info: Reading total current from td.general/total_current')
      call messages_info()

      ! Opens the coordinates files.
      iunit = io_open('td.general/total_current', action='read')

      call io_skip_header(iunit)

      ntime = 1
      iter = 1

      ! check the number of time steps we will read
      do
        read(unit = iunit, iostat = ierr, fmt = *) read_iter, curtime

        curtime = units_to_atomic(units_out%time, curtime)

        if(ierr /= 0 .or. curtime >= spectrum%end_time) then
          iter = iter - 1	! last iteration is not valid
          ntime = ntime - 1
          exit
        end if
        
        if(iter /= read_iter + 1) then
          call messages_write("Error while reading file 'td.general/total_current',", new_line = .true.)
          call messages_write('expected iteration ')
          call messages_write(iter - 1)
          call messages_write(', got iteration ')
          call messages_write(read_iter)
          call messages_write('.')
          call messages_fatal()
        end if
        
        ! ntime counts how many steps are gonna be used
        if (curtime >= spectrum%start_time .and. mod(iter, skip) == 0) ntime = ntime + 1 

        iter = iter + 1 !counts number of timesteps (with time larger than zero up to SpecEndTime)
      end do
      
      call io_close(iunit)

      SAFE_ALLOCATE(total_current(1:3, 1:ntime))
      SAFE_ALLOCATE(heat_current(1:3, 1:ntime))
      SAFE_ALLOCATE(time(1:ntime))
      
      iunit = io_open('td.general/total_current', action='read', status='old', die=.false.)
      
      if(iunit > 0) then
        
        call io_skip_header(iunit)
        
        do iter = 1, ntime
          read(unit = iunit, iostat = ierr, fmt = *) read_iter, time(iter), &
            total_current(1, iter), total_current(2, iter), total_current(3, iter)
        end do
        
        call io_close(iunit)
        
      else
        
        call messages_write("Cannot find the 'td.general/total_current' file.")
        call messages_write(" Conductivity will only be calculated from the forces")
        call messages_warning()
        
        total_current(1:3, 1:ntime) = CNST(0.0)
        
      end if

         iunit = io_open('td.general/total_heat_current', action='read', status='old', die=.false.)
      
      if(iunit > 0) then
        
        call io_skip_header(iunit)
        
        do iter = 1, ntime
          read(unit = iunit, iostat = ierr, fmt = *) read_iter, time(iter), &
            heat_current(1, iter), heat_current(2, iter), heat_current(3, iter)
          !write(*,*)heat_current(1, iter), heat_current(2, iter), heat_current(3, iter)
       end do
        
       call io_close(iunit)
       
      else
        
        call messages_write("Cannot find the 'td.general/heat_current' file.")
        call messages_write(" Conductivity will only be calculated from the forces")
        call messages_warning()
        
        heat_current(1:3, 1:ntime) = CNST(0.0)
        
      end if
   end if
   
    deltat = time(2) - time(1)
      

    SAFE_ALLOCATE(curr(ntime, 1:3, 1:1))
    SAFE_ALLOCATE(heatcurr(ntime, 1:3, 1:1))
    integral = CNST(0.0)

    if(from_forces) iunit = io_open('td.general/current_from_forces', action='write')

    do iter = 1, ntime

      if(from_forces) then
        if(iter == 1) then
          vel0 = CNST(0.0)
          ivel = 1
          do ii = 1, geo%natoms
            do jj = 1, space%dim
              vel0(jj) = vel0(jj) + velocities(ivel, iter)/dble(geo%natoms)
              ivel = ivel + 1
            end do
          end do
        end if
        
        velcm = CNST(0.0)
        current = CNST(0.0)
        
        ivel = 1
        do ii = 1, geo%natoms
          do jj = 1, space%dim
            velcm(jj) = velcm(jj) + velocities(ivel, iter)/dble(geo%natoms)
            current(jj) = current(jj) + species_mass(geo%atom(ii)%species)/sb%rcell_volume*(velocities(ivel, iter) - vel0(jj))
            ivel = ivel + 1
          end do
        end do
        
        integral(1) = integral(1) + deltat/vel0(1)*(vel0(1)*st%qtot/sb%rcell_volume + current(1))
        integral(2) = integral(2) + deltat/vel0(1)*(vel0(1)*st%qtot/sb%rcell_volume - total_current(1, iter)/sb%rcell_volume)

        curr(iter, 1:space%dim, 1) = vel0(1:space%dim)*st%qtot/sb%rcell_volume + current(1:space%dim)
       
      else
        curr(iter, 1:space%dim, 1) = total_current(1:space%dim, iter)/sb%rcell_volume
        heatcurr(iter,1:space%dim,1)=heat_current(1:space%dim,iter)/sb%rcell_volume
      end if
        
      if(from_forces) write(iunit,*) iter, iter*deltat,  curr(iter, 1:space%dim, 1)
      
    end do

    if(from_forces) call io_close(iunit)
    SAFE_ALLOCATE(ftcurr(1:max_freq, 1:3, 1:2))

    ftcurr = M_ONE

    call batch_init(currb, 3, 1, 1, curr)

    call spectrum_signal_damp(spectrum%damp, spectrum%damp_factor, 1, ntime, M_ZERO, deltat, currb)

    call batch_init(ftcurrb, 3, 1, 1, ftcurr)
    call spectrum_fourier_transform(spectrum%method, SPECTRUM_TRANSFORM_COS, spectrum%noise, &
      1, ntime, M_ZERO, deltat, currb, 1, max_freq, spectrum%energy_step, ftcurrb)
    call batch_end(ftcurrb)

    call batch_init(ftcurrb, 3, 1, 1, ftcurr(:, :, 2:2))
    call spectrum_fourier_transform(spectrum%method, SPECTRUM_TRANSFORM_SIN, spectrum%noise, &
      1, ntime, M_ZERO, deltat, currb, 1, max_freq, spectrum%energy_step, ftcurrb)
    call batch_end(ftcurrb)
    
    call batch_end(currb)


    !and print the spectrum
    iunit = io_open('td.general/conductivity', action='write')

    
    write(unit = iunit, iostat = ierr, fmt = '(a)') &
      '###########################################################################################################################'
    write(unit = iunit, iostat = ierr, fmt = '(8a)')  '# HEADER'
    write(unit = iunit, iostat = ierr, fmt = '(a,a,a)') &
      '#  Energy [', trim(units_abbrev(units_out%energy)), '] Conductivity [a.u.] ReX ImX ReY ImY ReZ ImZ'
    write(unit = iunit, iostat = ierr, fmt = '(a)') &
      '###########################################################################################################################'

    v0 = sqrt(sum(vel0(1:space%dim)**2))
    if(.not. from_forces .or. v0 < epsilon(v0)) v0 = CNST(1.0)
    do ifreq = 1, max_freq
      ww = spectrum%energy_step*(ifreq - 1)
      write(unit = iunit, iostat = ierr, fmt = '(7e20.10)') units_from_atomic(units_out%energy, ww), &
           transpose(ftcurr(ifreq, 1:3, 1:2)/v0)
      !write(*,*)ifreq, ftcurr(ifreq, 1:3, 1:2)
    end do
    
    call io_close(iunit)
    
    SAFE_DEALLOCATE_A(ftcurr)
    
!!!!!!!!!!!!!!!!!!!!!
    SAFE_ALLOCATE(ftheatcurr(1:max_freq, 1:3, 1:2))

    ftheatcurr = M_ONE

    call batch_init(heatcurrb, 3, 1, 1, heatcurr)
    
    call spectrum_signal_damp(spectrum%damp, spectrum%damp_factor, 1, ntime, M_ZERO, deltat, heatcurrb)

    call batch_init(ftheatcurrb, 3, 1, 1, ftheatcurr)
    call spectrum_fourier_transform(spectrum%method, SPECTRUM_TRANSFORM_COS, spectrum%noise, &
      1, ntime, M_ZERO, deltat, heatcurrb, 1, max_freq, spectrum%energy_step, ftheatcurrb)
    call batch_end(ftheatcurrb)

    call batch_init(ftheatcurrb, 3, 1, 1, ftheatcurr(:, :, 2:2))
    call spectrum_fourier_transform(spectrum%method, SPECTRUM_TRANSFORM_SIN, spectrum%noise, &
      1, ntime, M_ZERO, deltat, heatcurrb, 1, max_freq, spectrum%energy_step, ftheatcurrb)
    call batch_end(ftheatcurrb)
    
    call batch_end(heatcurrb)


    !and print the spectrum
    iunit = io_open('td.general/heat_conductivity', action='write')

    
    write(unit = iunit, iostat = ierr, fmt = '(a)') &
      '###########################################################################################################################'
    write(unit = iunit, iostat = ierr, fmt = '(8a)')  '# HEADER'
    write(unit = iunit, iostat = ierr, fmt = '(a,a,a)') &
      '#  Energy [', trim(units_abbrev(units_out%energy)), '] Conductivity [a.u.] ReX ImX ReY ImY ReZ ImZ'
    write(unit = iunit, iostat = ierr, fmt = '(a)') &
      '###########################################################################################################################'

    v0 = sqrt(sum(vel0(1:space%dim)**2))
    if(.not. from_forces .or. v0 < epsilon(v0)) v0 = CNST(1.0)

    do ifreq = 1, max_freq
      ww = spectrum%energy_step*(ifreq - 1)
      write(unit = iunit, iostat = ierr, fmt = '(7e20.10)') units_from_atomic(units_out%energy, ww), &
        transpose(ftheatcurr(ifreq, 1:3, 1:2)/v0)
      !print *, ifreq, ftheatcurr(ifreq, 1:3, 1:2)
   end do
    
    call io_close(iunit)
    
    SAFE_DEALLOCATE_A(ftheatcurr)
!!!!!!!!!!!!!!!!!!!!!!!!!!!

    
    call simul_box_end(sb)
    call geometry_end(geo)
    call space_end(space)

    SAFE_DEALLOCATE_A(time)

    call io_end()
    call messages_end()
    call global_end()

  end program conductivity

!! Local Variables:
!! mode: f90
!! coding: utf-8
!! End:
