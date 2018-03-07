#ifndef PSEUDO_BASE_HPP
#define PSEUDO_BASE_HPP

#include <vector>
#include <string>

namespace pseudopotential {

  enum class type { ULTRASOFT = 30, NORM_CONSERVING = 31, KLEINMAN_BYLANDER = 32};
  
  class base {

  public:

    virtual ~base(){}
    virtual pseudopotential::type type() const { return type_; }
    virtual int lmax() const { return lmax_; }

    //Pure virtual functions
    virtual std::string format() const = 0;
    virtual int size() const = 0;
    virtual std::string description() const = 0;
    virtual std::string symbol() const = 0;
    virtual int atomic_number() const = 0;
    virtual double mass() const = 0;
    virtual int valence_charge() const = 0;
    virtual int llocal() const = 0;
    virtual int nchannels() const = 0;
    virtual int nquad() const = 0;
    virtual double rquad() const = 0;
    virtual double mesh_spacing() const = 0;
    virtual int mesh_size() const = 0;
    virtual void local_potential(std::vector<double> & potential) const = 0;
    virtual int nprojectors() const = 0;
    virtual bool has_projectors(int l) const = 0;
    virtual void projector(int l, int i, std::vector<double> & proj) const = 0;
    virtual double d_ij(int l, int i, int j) const = 0;
    virtual bool has_radial_function(int l) const= 0;
    virtual void radial_function(int l, std::vector<double> & function) const = 0;
    virtual void radial_potential(int l, std::vector<double> & function) const = 0;
    virtual bool has_nlcc() const= 0;
    virtual void nlcc_density(std::vector<double> & density) const = 0;
    virtual void beta(int index, int & l, std::vector<double> & proj) const = 0;
    virtual void dnm_zero(int nbeta, std::vector<std::vector<double> > & dnm) const = 0;
    virtual bool has_rinner() const = 0;
    virtual void rinner(std::vector<double> & val) const = 0;
    virtual void qnm(int index, int & l1, int & l2, int & n, int & m, std::vector<double> & val) const = 0;
    virtual void qfcoeff(int index, int ltot, std::vector<double> & val) const = 0;
    
  protected:

    pseudopotential::type type_;
    int lmax_;
    
  };

}

#endif
