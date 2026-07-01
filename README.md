# CLEM-CAT
Correlateive Light Electron Microscopy - Cross-alignment Tool

CLEM-CAT is a manual multimodal alignment tool using the matlab app framework to allow for alignment of images across large range scales. 

# Installation
 1) Download CrossAlignmentTool.mlapp, alignedImageexporter.m, compressedImg.m, imgMerge.m to the same folder
 2) Install matlab
 3) Run CrossAlignmentTool.mlapp

# Version History 
1.0.0
  - CLEM-CAT published to repository
  - Known bugs
      - Invert followed by rotation can lead to increasing image size reduction
      - Close functionality is inconsistent
      - Some img1/img2 control panel functionality leads to the incorrect display of an image when the other single image mode is selected

1.0.1  Critical bug fixes
  - ROI export selector would not capture correct area due to improper basing of D1 D2 limits for each tile
  - Slight destructive tile overlap based on rounding error in larger images fixed by forcing tile rescaling

# TODO
  - Compile into distributable app
  - fix bugs for 1.0.2
