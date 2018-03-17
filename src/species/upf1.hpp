#ifndef PSEUDO_UPF1_HPP
#define PSEUDO_UPF1_HPP

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

#include <fstream>
#include <vector>
#include <cassert>
#include <sstream>
#include <iostream>
#include <cmath>

#include "base.hpp"
#include <rapidxml.hpp>

#include "chemical_element.hpp"
#include "spline.h"

namespace pseudopotential {

  class upf1 : public pseudopotential::base {

  public:
    
    upf1(const std::string & filename):
      file_(filename),
      buffer_((std::istreambuf_iterator<char>(file_)), std::istreambuf_iterator<char>()){

      buffer_.push_back('\0');
      doc_.parse<0>(&buffer_[0]);
      
      std::istringstream header(doc_.first_node("PP_HEADER")->value());

      std::string line;

      int version_number;
      header >> version_number;
      getline(header, line);
      
      header >> symbol_;
      getline(header, line);
      
      std::string pseudo_type;
      header >> pseudo_type;
      getline(header, line);

      //nlcc tag
      getline(header, line);

      getline(header, xc_functional_);

      header >> zval_;
      getline(header, line);

      //total energy
      getline(header, line);

      //cutoff
      getline(header, line);

      header >> lmax_;
      getline(header, line);

      int size;
      header >> size;
      getline(header, line);

      header >> nwavefunctions_;
      header >> nprojectors_;
      getline(header, line);

      std::transform(pseudo_type.begin(), pseudo_type.end(), pseudo_type.begin(), ::tolower);

      if(pseudo_type == "nc" || pseudo_type == "sl"){
	type_ = pseudopotential::type::KLEINMAN_BYLANDER;
      } else if(pseudo_type == "uspp"){
	throw status::UNSUPPORTED_TYPE_ULTRASOFT;
      } else if(pseudo_type == "paw") {
	throw status::UNSUPPORTED_TYPE_PAW;
      } else {
	throw status::UNSUPPORTED_TYPE;
      }

      // Read the grid
      {
	rapidxml::xml_node<> * node = doc_.first_node("PP_MESH")->first_node("PP_R");
	assert(node);

	std::istringstream stst(node->value());

	//check whether the first point is zero or not
	double xmin;
	stst >> xmin;

	start_point_ = 0;
	if(xmin > 1.0e-10) start_point_ = 1;

	grid_.resize(size + start_point_);

	grid_[0] = 0.0;
	grid_[start_point_] = xmin;
	for(int ii = 0; ii < size - 1; ii++) stst >> grid_[1 + start_point_ + ii];
	
	assert(fabs(grid_[0]) <= 1e-10);

	mesh_size_ = 0;
	for(double rr = 0.0; rr <= grid_[grid_.size() - 1]; rr += mesh_spacing()) mesh_size_++;
	
      }

      //Read dij once
      {
      	rapidxml::xml_node<> * node = doc_.first_node("PP_NONLOCAL");//->first_node("PP_DIJ");

	assert(node);
	
	dij_.resize(nprojectors()*nprojectors());
	for(unsigned kk = 0; kk < dij_.size(); kk++) dij_[kk] = 0.0;
	
	std::istringstream stst(node->value());

	int nnonzero;

	stst >> nnonzero;
	getline(stst, line);
	
	for(int kk = 0; kk < nnonzero; kk++){
	  int ii, jj;
	  double val;
	  stst >> ii >> jj >> val;
	  val *= 0.5; //convert from Rydberg to Hartree
	  ii--;
	  jj--;
	  dij_[ii + jj*nprojectors()] = val;
	  dij_[jj + ii*nprojectors()] = val;
	}
      }

      assert(lmax_ >= 0);
    }

    pseudopotential::format format() const { return pseudopotential::format::UPF2; }
    
    int size() const { return buffer_.size(); };

    std::string description() const {
      return doc_.first_node("PP_INFO")->value();
    }
    
    std::string symbol() const {
      return symbol_;
    }

    int atomic_number() const {
      chemical_element el(symbol());
      return el.atomic_number();
    }

    double mass() const {
      chemical_element el(symbol());
      return el.mass();
    }
    
    int valence_charge() const {
      return zval_;
    }

    int llocal() const {
      //      int ll = value<int>(doc_.first_node("PP_HEADER")->first_attribute("l_local"));
      //      return std::max(-1, ll);
      return -1;
    }

    pseudopotential::exchange exchange() const {
      std::string functional = doc_.first_node("PP_HEADER")->first_attribute("functional")->value();
      if(functional == "PBE") return pseudopotential::exchange::PBE;
      if(functional == "PBESOL") return pseudopotential::exchange::PBE_SOL;
      if(functional == "SLA  PW   NOGX NOGC") return pseudopotential::exchange::LDA;
      if(functional == "BLYP") return pseudopotential::exchange::B88;
      return pseudopotential::exchange::UNKNOWN;
    }

    pseudopotential::correlation correlation() const {
      std::string functional = doc_.first_node("PP_HEADER")->first_attribute("functional")->value();
      if(functional == "PBE") return pseudopotential::correlation::PBE;
      if(functional == "PBESOL") return pseudopotential::correlation::PBE_SOL;
      if(functional == "SLA  PW   NOGX NOGC") return pseudopotential::correlation::LDA_PW;
      if(functional == "BLYP") return pseudopotential::correlation::LYP;
      return pseudopotential::correlation::UNKNOWN;
    }

    
    int nquad() const {
      return 0;
    }

    double rquad() const {
      return 0.0;
    }

    double mesh_spacing() const {
      return 0.01;
    }

    int mesh_size() const {
      return mesh_size_;
    }
    
    int nchannels() const {
      if(llocal() >= 0){
	return nprojectors()/lmax();
      } else {
	return nprojectors()/(lmax() + 1);
      }
    }
    
    void local_potential(std::vector<double> & potential) const {
      rapidxml::xml_node<> * node = doc_.first_node("PP_LOCAL");

      assert(node);

      potential.resize(grid_.size() + start_point_);
      std::istringstream stst(node->value());
      for(unsigned ii = 0; ii < grid_.size(); ii++) {
	stst >> potential[ii + start_point_];
	potential[ii] *= 0.5; //Convert from Rydberg to Hartree
      }
      if(start_point_ > 0) extrapolate_first_point(potential);

      interpolate(potential);
      
    }

    int nprojectors() const {
      return nprojectors_;
    }
    
    void projector(int l, int i, std::vector<double> & proj) const {
      rapidxml::xml_node<> * node = NULL;

      for(int iproj = 1; iproj <= nprojectors(); iproj++){
	std::string tag = "PP_BETA." + std::to_string(iproj);
	node = doc_.first_node("PP_NONLOCAL")->first_node(tag.c_str());

	assert(node);
	
	int read_l = value<int>(node->first_attribute("angular_momentum"));
	int read_i = (value<int>(node->first_attribute("index")) - 1)%nchannels();
	if(l == read_l && i == read_i) break;
      }

      assert(node);

      int size = value<int>(node->first_attribute("size"));
      proj.resize(size + start_point_);
      std::istringstream stst(node->value());
      for(int ii = 0; ii < size; ii++) stst >> proj[ii + start_point_];

      //the projectors come multiplied by r, so we have to divide and fix the first point
      for(int ii = 1; ii < size + start_point_; ii++) proj[ii] /= grid_[ii];
      extrapolate_first_point(proj);
      
      interpolate(proj);
    }
    
    double d_ij(int l, int i, int j) const {
      int n = l*nchannels() + i;
      int m = l*nchannels() + j;

      return dij_[n*nprojectors() + m];
    }

    bool has_radial_function(int l) const{
      return false;
    }

    void radial_function(int l, std::vector<double> & function) const {
      function.clear();
    }

    void radial_potential(int l, std::vector<double> & function) const {
      function.clear();
    }

    bool has_nlcc() const{
      return doc_.first_node("PP_NLCC");
    }

    void nlcc_density(std::vector<double> & density) const {
      rapidxml::xml_node<> * node = doc_.first_node("PP_NLCC");
      assert(node);
      
      int size = value<int>(node->first_attribute("size"));
      density.resize(size);

      std::istringstream stst(node->value());
      for(int ii = 0; ii < size; ii++) stst >> density[start_point_ + ii];
      extrapolate_first_point(density);
      // this charge does not come multiplied by anything
      
      interpolate(density);
    }
    
    void beta(int iproj, int & l, std::vector<double> & proj) const {
      rapidxml::xml_node<> * node = NULL;

      std::string tag = "PP_BETA." + std::to_string(iproj + 1);
      node = doc_.first_node("PP_NONLOCAL")->first_node(tag.c_str());

      assert(node);
	
      l = value<int>(node->first_attribute("angular_momentum"));

      int size = value<int>(node->first_attribute("size"));
      proj.resize(size + start_point_);
      std::istringstream stst(node->value());
      for(int ii = 0; ii < size; ii++) stst >> proj[ii + start_point_];

      //the projectors come multiplied by r, so we have to divide and fix the first point
      for(int ii = 1; ii < size + start_point_; ii++) proj[ii] /= grid_[ii];
      extrapolate_first_point(proj);
      
      interpolate(proj);
    }

    void dnm_zero(int nbeta, std::vector<std::vector<double> > & dnm) const {
      dnm.resize(nbeta);
      for(int i = 0; i < nbeta; i++){
	dnm[i].resize(nbeta);
	for ( int j = 0; j < nbeta; j++){
	  dnm[i][j] = dij_[i*nbeta + j];
	}
      }
    }

    bool has_rinner() const {
      return false;
    }
    
    void rinner(std::vector<double> & val) const {
      val.clear();
    }

    void qnm(int index, int & l1, int & l2, int & n, int & m, std::vector<double> & val) const {
      val.clear();
    }

    void qfcoeff(int index, int ltot, std::vector<double> & val) const {
      val.clear();
    }

    bool has_density(){
      return doc_.first_node("PP_RHOATOM");
    }
      
    void density(std::vector<double> & val) const {
      rapidxml::xml_node<> * node = doc_.first_node("PP_RHOATOM");
      assert(node);
      
      int size = value<int>(node->first_attribute("size"));
      val.resize(size);
      
      std::istringstream stst(node->value());
      for(int ii = 0; ii < size; ii++) stst >> val[start_point_ + ii];

      // the density comes multiplied by 4\pi r
      for(int ii = 1; ii < size + start_point_; ii++) val[ii] /= 4.0*M_PI*grid_[ii]*grid_[ii];
      extrapolate_first_point(val);
      
      interpolate(val);
    }

    int nwavefunctions() const {
      return nwavefunctions_;
    }
    
    void wavefunction(int index, int & n, int & l, double & occ, std::vector<double> & proj) const {
      rapidxml::xml_node<> * node = NULL;
      
      std::string tag = "PP_CHI." + std::to_string(index + 1);
      node = doc_.first_node("PP_PSWFC")->first_node(tag.c_str());
      
      assert(node);

      // not all files have "n", so we might have to parse the label
      if(node->first_attribute("n")){
	n = value<int>(node->first_attribute("n"));
      } else {
	std::string label = node->first_attribute("label")->value();
	n = std::stoi(label.substr(0, 1));
      }
      
      l = value<int>(node->first_attribute("l"));

      occ = value<double>(node->first_attribute("occupation"));
      
      int size = value<int>(node->first_attribute("size"));
      proj.resize(size + start_point_);
      std::istringstream stst(node->value());
      for(int ii = 0; ii < size; ii++) stst >> proj[ii + start_point_];

      //the wavefunctions come multiplied by r, so we have to divide and fix the first point
      for(int ii = 1; ii < size + start_point_; ii++) proj[ii] /= grid_[ii];
      extrapolate_first_point(proj);
      
      interpolate(proj);
    }
    
  private:

    void interpolate(std::vector<double> & function) const {
      std::vector<double> function_in_grid = function;
      
      Spline function_spline;
      function_spline.fit(grid_.data(), function_in_grid.data(), function_in_grid.size(), SPLINE_FLAT_BC, SPLINE_NATURAL_BC);

      function.clear();
      for(double rr = 0.0; rr <= grid_[grid_.size() - 1]; rr += mesh_spacing()){
	function.push_back(function_spline.value(rr));
      }
    }
    
    void extrapolate_first_point(std::vector<double> & function_) const{
      double x1 = grid_[1];
      double x2 = grid_[2];
      double x3 = grid_[3];
      double f1 = function_[1];
      double f2 = function_[2];
      double f3 = function_[3];


      // obtained from:
      // http://www.wolframalpha.com/input/?i=solve+%7Bb*x1%5E2+%2B+c*x1+%2B+d+%3D%3D+f1,++b*x2%5E2+%2B+c*x2+%2B+d+%3D%3D+f2,+b*x3%5E2+%2B+c*x3+%2B+d+%3D%3D+f3+%7D++for+b,+c,+d
      
      function_[0] = f1*x2*x3*(x2 - x3) + f2*x1*x3*(x3 - x1) + f3*x1*x2*(x1 - x2);
      function_[0] /= (x1 - x2)*(x1 - x3)*(x2 - x3);

    }
    
    std::ifstream file_;
    std::vector<char> buffer_;
    rapidxml::xml_document<> doc_;
    std::vector<double> grid_;
    std::vector<double> dij_;
    int start_point_;
    int mesh_size_;

    std::string symbol_;
    std::string xc_functional_;
    int zval_;
    int nwavefunctions_;
    int nprojectors_;
    
    
  };

}

#endif
