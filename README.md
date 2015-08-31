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
cd dcs-template-insar-diapason-s1
mvn install
```


### Processing overview

This service creates the interferometric phase,coherence and reflectivity from a Sentinel-1 InSAR pair (IW SLC data)


#### Input description

This template application uses as input a pair (Master;Slave) of Sentinel 1 products. 

If you run this template application using local file URLs stored on a shared folder like /tmp, pass an input pair e.g.:


```
/tmp/S1A_IW_SLC__1SDV_20150120T014642_20150120T014655_004248_0052B6_C334.zip;/tmp/S1A_IW_SLC__1SDV_20150309T014641_20150309T014655_004948_0062FF_DB55.zip
``


To discover and download master/slave Sentinel-1 products, use either the [ESA Sentinel-1 Scientific Data Hub](https://scihub.esa.int/dhus/) or the [Geohazards Thematic Exploitation platform](https://geohazards-tep.eo.esa.int).

You can also run this template application using catalogue URLs for input references, as provided by the [Geohazards Thematic Exploitation platform](https://geohazards-tep.eo.esa.int) e.g:

```
https://data.terradue.com/gs/catalogue/tepqw/gtfeature/search?uid=/tmp/S1A_IW_SLC__1SDV_20150120T014642_20150120T014655_004248_0052B6_C334;https://data.terradue.com/gs/catalogue/tepqw/gtfeature/search?uid=/tmp/S1A_IW_SLC__1SDV_20150309T014641_20150309T014655_004948_0062FF_DB55
```
and then let the application download them from the Data Hub. 

Please contact the Operational Support team at Terradue in order to set your ESA Sentinel-1 Scientific Data Hub credentials on your Development Cloud Sandbox.





