## Developer Cloud Sandbox for InSAR interferogram generation with the Diapason processor 


This package contains wrapper scripts for InSAR processing of Sentinel-1 TOPSAR  pairs with the Diapason software.
Diapason is a proprietary InSAR processing system maintained by Altamira-Information (wwww.altamira-information.com)

### Getting started

This application requires the diapason package to be installed , and runs on a Developer Cloud Sandbox , that can be either requested from:
* ESA [Geohazards Exploitation Platform](https://geohazards-tep.eo.esa.int) for GEP early adopters;
* ESA [Research & Service Support Portal](http://eogrid.esrin.esa.int/cloudtoolbox/) for ESA G-POD related projects and ESA registered user accounts
* From [Terradue's Portal](http://www.terradue.com/partners), provided user registration approval. 


### Installation

Log on your developer cloud sandbox and from a command line shell ,run the following commands :

```bash
git clone git@github.com:pordoqui/dcs-template-insar-diapason-s1.git
cd dcs-template-insar-diapason
mvn install
```


### Processing overview

This service creates the interferometric phase,coherence and reflectivity from an InSAR pair .





