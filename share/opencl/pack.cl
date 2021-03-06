/*
 Copyright (C) 2010 X. Andrade

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2, or (at your option)
 any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 02110-1301, USA.

*/

#include <cl_global.h>

__kernel void dpack(const int nst,
		    const int np,
		    const int ist,
		    const __global double * restrict src, 
		    __global double *  restrict dest){
  const int ip = get_global_id(0);
  const int ist2 = get_global_id(1);

  if(ip < np) dest[ist + ist2 + ip*nst] = src[ip + ist2*get_global_size(0)];
}

__kernel void zpack(const int nst,
		    const int np,
		    const int ist,
		    const __global double2 *  restrict src, 
		    __global double2 *  restrict dest){
  const int ip = get_global_id(0);
  const int ist2 = get_global_id(1);

  if(ip < np) dest[ist + ist2 + ip*nst] = src[ip + ist2*get_global_size(0)];
}

__kernel void dunpack(const int nst,
		      const int np,
		      const int ist,
		      const __global double * restrict src, 
		      __global double *  restrict dest){
  const int ist2 = get_global_id(0);
  const int ip = get_global_id(1);

  if(ip < np) dest[ip + ist2*get_global_size(1)] = src[ist + ist2 + ip*nst];
}

__kernel void zunpack(const int nst,
		      const int np,
		      const int ist,
		      const __global double2 * restrict src, 
		      __global double2 * restrict dest){
  const int ist2 = get_global_id(0);
  const int ip = get_global_id(1);

  if(ip < np) dest[ip + ist2*get_global_size(1)] = src[ist + ist2 + ip*nst];
}


/*
 Local Variables:
 mode: c
 coding: utf-8
 End:
*/
