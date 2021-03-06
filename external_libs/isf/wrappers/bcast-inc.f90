!> @file
!! Include fortran file for broadcast operations
!! @author
!!    Copyright (C) 2012-2013 BigDFT group
!!    This file is distributed under the terms of the
!!    GNU General Public License, see ~/COPYING file
!!    or http://www.gnu.org/copyleft/gpl.txt .
!!    For the list of contributors, see ~/AUTHORS

  iroot=0
  if (present(root)) iroot=root
  mpi_comm=MPI_COMM_WORLD
  if (present(comm)) mpi_comm=comm
  if (present(check)) chk=check
  !performs debug check if active
  if (chk) then
     !first, verify that everybody came here
     if (mpirank(mpi_comm) == 0) then
        call yaml_mapping_open('BCAST check')
        call yaml_comment('Barrier over all processes')
     end if
     call mpibarrier(comm=mpi_comm)
     if (mpirank(mpi_comm) == 0) call yaml_flush_document()
     !if barrier passed, verify that the size of the communicated objects is the same
     ierr=mpimaxdiff([n,mpitype(buffer),iroot],comm=mpi_comm)
     !inform that everything seems OK
     if (mpirank(mpi_comm) == 0) then
        call yaml_map('Check passed',ierr == 0)
        call yaml_mapping_close()
        call yaml_flush_document()
     end if
  end if

  !no bcast if size is zero
  if (n==0) return

  call MPI_BCAST(buffer,n,mpitype(buffer),iroot,mpi_comm,ierr)
  if (ierr /=0) then
     call f_err_throw('An error in calling to MPI_BCAST occured',&
          err_id=ERR_MPI_WRAPPERS)
     return
  end if

  if (chk) then
     call mpibarrier(comm=mpi_comm)
     if (mpirank(mpi_comm) == 0) then
        call yaml_comment('Actual Broadcast terminated') 
        call yaml_flush_document()
     end if
  end if
