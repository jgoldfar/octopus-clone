/*
 Copyright (C) 2018 Xavier Andrade

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation; either version 3 of the License, or
 (at your option) any later version.
  
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Lesser General Public License for more details.
  
 You should have received a copy of the GNU Lesser General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*/

#include <sys/stat.h>
#include <algorithm>

#include "string_f.h" /* fortran <-> c string compatibility issues */

#include "fortran_types.h"

#include "base.hpp"
#include "qso.hpp"
#include "upf.hpp"


enum class status {
  OKAY                  = 0,
  FILE_NOT_FOUND        = 455,
  FORMAT_NOT_SUPPORTED  = 456,
  UNKNOWN_FORMAT        = 457
};

extern "C" void FC_FUNC_(pseudo_init, PSEUDO_INIT)(pseudopotential::base ** pseudo, STR_F_TYPE const filename_f, fint * ierr STR_ARG1){
  char * filename_c;
  TO_C_STR1(filename_f, filename_c);
  std::string filename(filename_c);
  free(filename_c);

  *ierr = 0;
  
  struct stat statbuf;
  bool found_file = !stat(filename.c_str(), &statbuf);

  if(!found_file){
    *ierr = fint(status::FILE_NOT_FOUND);
    return;
  }
  
  std::string extension = filename.substr(filename.find_last_of(".") + 1);
  std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
  
  std::cout << "  Opening file " << filename << std::endl;
  
  *pseudo = NULL;
  
  if(extension == "xml"){
    *pseudo = new pseudopotential::qso(filename);
  } else if(extension == "upf") {
    *pseudo = new pseudopotential::upf(filename);
  } else {
    std::cerr << "Unknown pseudopotential type" << std::endl;
    exit(1);
  }

  assert(*pseudo);
  
}

extern "C" void FC_FUNC_(pseudo_end, PSEUDO_END)(pseudopotential::base ** pseudo){
  delete *pseudo;
}

extern "C" fint FC_FUNC_(pseudo_type, PSEUDO_TYPE)(const pseudopotential::base ** pseudo){
  return fint((*pseudo)->type());
}

extern "C" double FC_FUNC_(pseudo_valence_charge, PSEUDO_VALENCE_CHARGE)(const pseudopotential::base ** pseudo){
  return (*pseudo)->valence_charge();
}

extern "C" double FC_FUNC_(pseudo_mesh_spacing, PSEUDO_MESH_SPACING)(const pseudopotential::base ** pseudo){
  return (*pseudo)->mesh_spacing();
}

extern "C" fint FC_FUNC_(pseudo_mesh_size, PSEUDO_MESH_SIZE)(const pseudopotential::base ** pseudo){
  return (*pseudo)->mesh_size();
}

extern "C" double FC_FUNC_(pseudo_mass, PSEUDO_MASS)(const pseudopotential::base ** pseudo){
  return (*pseudo)->mass();
}

extern "C" fint FC_FUNC_(pseudo_lmax, PSEUDO_LMAX)(const pseudopotential::base ** pseudo){
  return (*pseudo)->lmax();
}

extern "C" fint FC_FUNC_(pseudo_llocal, PSEUDO_LLOCAL)(const pseudopotential::base ** pseudo){
  return (*pseudo)->llocal();
}

extern "C" fint FC_FUNC_(pseudo_nchannels, PSEUDO_NCHANNELS)(const pseudopotential::base ** pseudo){
  return (*pseudo)->nchannels();
}

extern "C" fint FC_FUNC_(pseudo_has_projectors_low, PSEUDO_HAS_PROJECTORS_LOW)(const pseudopotential::base ** pseudo, const fint * l){
  return fint((*pseudo)->has_projectors(*l));
}

extern "C" void FC_FUNC_(pseudo_local_potential, PSEUDO_LOCAL_POTENTIAL)(const pseudopotential::base ** pseudo, double * local_potential){
  std::vector<double> val;
  (*pseudo)->local_potential(val);
  for(unsigned i = 0; i < val.size(); i++) local_potential[i] = val[i];
}

extern "C" void FC_FUNC_(pseudo_projector, PSEUDO_PROJECTOR)(const pseudopotential::base ** pseudo, fint * l, fint * ic, double * projector){
  std::vector<double> val;
  (*pseudo)->projector(*l, *ic, val);
  for(unsigned i = 0; i < val.size(); i++) projector[i] = val[i];
}

extern "C" double FC_FUNC_(pseudo_dij, PSEUDO_DIJ)(const pseudopotential::base ** pseudo, fint * l, fint * ic, fint * jc){
  return (*pseudo)->d_ij(*l, *ic, *jc);
}

extern "C" void FC_FUNC_(pseudo_radial_potential, PSEUDO_RADIAL_POTENTIAL)(const pseudopotential::base ** pseudo, fint * l,double * radial_potential){
  std::vector<double> val;
  (*pseudo)->radial_potential(*l, val);
  for(unsigned i = 0; i < val.size(); i++) radial_potential[i] = val[i];
}

extern "C" void FC_FUNC_(pseudo_radial_function, PSEUDO_RADIAL_FUNCTION)(const pseudopotential::base ** pseudo, fint * l, double * radial_function){
  std::vector<double> val;
  (*pseudo)->radial_function(*l, val);
  for(unsigned i = 0; i < val.size(); i++) radial_function[i] = val[i];
}


extern "C" fint FC_FUNC_(pseudo_has_nlcc_low, PSEUDO_HAS_NLCC_LOW)(const pseudopotential::base ** pseudo){
  return fint((*pseudo)->has_nlcc());
}

extern "C" void FC_FUNC_(pseudo_nlcc_density, PSEUDO_NLCC_DENSITY)(const pseudopotential::base ** pseudo, double * nlcc_density){
  std::vector<double> val;
  (*pseudo)->nlcc_density(val);
  for(unsigned i = 0; i < val.size(); i++) nlcc_density[i] = val[i];
}
