    classdef alignedImageExporter < handle
    %library class to handle exporting images more intelligently from the
    %crossalignment tool. Essentially this coordinates the export of
    %specified regions of the aligned image. Plan is primarily to do that
    %by getting the pixels from the corresponding region in the original
    %image, then rotating and scaling to match the aligned image and saving
    %that. 
    %
    %The idea is this can then be used to export a specific region, or to
    %tile export the whole image without significant memory bottlenecks
    %that the old code was finding on large EM images leading to large
    %scaling of other iamges.

    properties
        %Global image rotation
        %Order of operations: rotate, scale, translate
        %in the constructor it'll pass to a function all the params to sort
        %this out and then once these are calculated everything is handled
        %within the class
        imageRotation % -180 to 180 deg
        imageScaling %vec of D1 and D2
        imageTranslation %vec of D1 and D2
        displaySpaceCentre % [d1 d2] centre positions of display space, such that we can adjust to 0,0 origined
    end

    methods(Access=public)
        function obj = alignedImageExporter(imageParams, displaySpaceSize)
            %constructor, just in case I use this for other shite  I'm
            %gonna build it so it takes an image params struct and a
            %origin tag. Then from that it'll pass to a translator to
            %return the rotation scaling and translation.
            %will do this first independently, then can write a function
            %to collapse the two to a smaller coordspace if needed
            arguments
                imageParams %Struct to give info on image rot, scaling, translation, varies based on input, must have inputSource as a thang
                displaySpaceSize
            end


            %check that the input source exists to direct which translation
            %func to use
            if ~isfield(imageParams,"inputSource")
                error("Need to pass inputSource field to aligned ImageExporter");
            end
           
            %future proofing
            switch imageParams.inputSource
                case "CAT" %Cross alignemnt Tool
                    [obj.imageRotation,obj.imageScaling,obj.imageTranslation] = obj.computeGlobalTransformCAT(imageParams);
                otherwise
                    error("Unknown inputSource")
            end

            obj.displaySpaceCentre = mean([1,1;displaySpaceSize]);

            %at this point we should have the global image parameters
            %sorted
        end

        function outImg = getAlignedAreaOfInterest(obj,imgData, globalCoordLimits)
            %function to return an image mat of data from some position
            %globally, but transformed to the mapping of aligned image.
            %Essentially, reverses the transformation to find the pixels,
            %grabs that part of the image, then transforms it and yeets it.
            %we do this instead of just taking the already displayed image,
            %so that things can be rescaled back up to full res
            %Will always make the minimium size image, representing the
            %area with no downscaling. Later functions provide second level
            %upscaling (as this should be lossless) to correct two types
            %Expects
            %   GlobalCoordLimits as [D1Lower, D1Lower; D1Upper, D2Upper]
            %   DisplaySpaceLimits as [D1Upper,D2Upper]
            %   ImgData as the raw full image data

            imageSpaceTargetCoords = obj.reverseCoordinates(globalCoordLimits, obj.getImageCentre(imgData));
            
            %now this will likely not be a grid aligned, so we want to take
            %these and get a grid aligned area, that is expanded such that
            %its not randomly got bits missing. Overhang refers to when
            %theres extra 0ed space because the selected area overflowed
            %the bounds of the original image

            [imgSpaceDataLimits,~] = obj.expandToSectionLimits(imageSpaceTargetCoords,size(imgData));

            %new attempt, we should cut out the image, rotate it, scale it
            %then place it based on where it should go etc

            relevantImageData = imgData(imgSpaceDataLimits(1,1):imgSpaceDataLimits(2,1),imgSpaceDataLimits(1,2):imgSpaceDataLimits(2,2));
            
            relevantImageData = imrotate(relevantImageData,obj.imageRotation);

             
            %now we need to work out where to put this imagePART
            %from imgSpaceDataLimits and original image data we can get the
            %vector from its centre to it (which we need to rotate)
            

            % We want to calculate the vector of Export (unscaled) Space Centre to
            % Image Part Centre

            % Export (unscaled) Space Centre > Display Space Origin (ie the corner)
            % just the coords of the Space Centre
            
            exportSpaceToDisplaySpaceCorner = -mean(globalCoordLimits);

            % Display Space Origin > Image 1 Centre
            % this is obj.imageTranslation

            % Image 1 Centre > Image 1 part centre
            % this is the coordinates of the centre of the image Part in
            % image space, but then we need to rotate it into
            % Display/Export space aligned, note this is already scaled 

            imageCentreToImagePartCentre = obj.rotateMatrixDeg((mean(imgSpaceDataLimits)-mean([1,1;size(imgData)]))',obj.imageRotation)';
               

            %we then get the limits and can crop and we don't need any more
            %info there 

            centrePositioningVector = (exportSpaceToDisplaySpaceCorner + obj.imageTranslation) ./ obj.imageScaling + imageCentreToImagePartCentre;


            %so we now want to displace the coordinates of the relevant
            %image data by the centre positioning vecotr from the centre of
            %scaled mean coordinates

            exportSpaceSize = floor((globalCoordLimits(2,:)-globalCoordLimits(1,:)) ./ obj.imageScaling);


            preTransformImage = obj.initaliseSimilarNumericMat(imgData,exportSpaceSize);
            

            %calculate posiitoning of the image in the export space
            %clipping measures the amount of lines we need to clip off each
            %side to fit it in the part limits
            [imagePartLimits, clipping] = obj.positionImageByCentre(centrePositioningVector, size(relevantImageData), exportSpaceSize);
            
            %Clip if needed, note where clipping is 0 nothing will happen
            relevantImageData = obj.clipImage(relevantImageData, clipping);


            %now we place the image where it should go, from image part
            %limits it should be cropped where needed

            %% NOTE: MIGHT NEED TO CHOP THE IMAGE FIRST to make sure it fits the image parts if it changed...
            %cann write a chop phrase into the above
            preTransformImage(imagePartLimits(1,1):imagePartLimits(2,1), imagePartLimits(1,2):imagePartLimits(2,2)) = relevantImageData;
            

            preTransformImage = imresize(preTransformImage,...
            Scale=obj.getMinimumResScalingScale(obj.imageScaling));

            %so at this point the image is correctly sized and rotated, so
            %we now just need to translate it to where it sits in the out
            %img. This should be defined by global coordinates for the
            %total image size, and then we translate it off centre by the
            %translation

            %I think technically it is already translated as well as that
            %was accomplished by the selection of the specific pixels and
            %any black space should be represented by the overhang?
            outImg = preTransformImage;


        end


        function [imageLimits, clipping] = positionImageByCentre(~,posVector, imageSize, spaceSize)
            %function to calculate the positoning of an image [lower1, lower2;
            %upper1, upper2] based on a centre offset vector, whilst
            %handling overflows of space size

            %calculate centre of space
            spaceCentre = mean([1,1;spaceSize]);
            
            %displace the image centre by the vector
            imageCentre = spaceCentre + posVector;

            %calculate edges
            halfImageSize = imageSize./2;
            imageLowerLimits = ceil(1+imageCentre - halfImageSize);
            imageUpperLimits = ceil(imageCentre + halfImageSize);

            %check for lowers under 1 or max above 1
            clipping = [0,0;0,0]; %on both sides just in case
            
            %loop through dimensions
            for dim = 1:length(imageUpperLimits)
                
                lowerLimitClip = 1 - imageLowerLimits(dim);
                
                if lowerLimitClip > 0
                    clipping(1,dim) = lowerLimitClip;
                    imageLowerLimits(dim) = 1;
                end
                
                upperLimitClip = imageUpperLimits(dim) - spaceSize(dim);
                if upperLimitClip > 0
                    clipping(2,dim) = upperLimitClip;
                    imageUpperLimits(dim) = spaceSize(dim);
                end
            end
            
            imageLimits = [imageLowerLimits;imageUpperLimits];
            
        end

        function revCoords = reverseCoordinates(obj,coords,imgCentre)
            %function to apply the transformation encoded in the class
            %Expects coords as [d1lower, d2lower; d1upper, d2upper]
            %note: d1 is y, d2 is x cos fuck matlab
            %returns 4 points as 

            %As images are rotated around their centre, we need to put them
            %into 0,0 centred space to rotate them. So first we remove the
            %translation and put them into image 0,0 centred space
            originedLimits = coords - obj.imageTranslation; 
            originedLimits = originedLimits + [-0.5; 0.5]; % accounts for
            %one more line cut than square, this means we're lookinmg at
            %the corners not the centres

            %now we can do the matrix bs to scale and rotate 
            %in order D1L;D2L D1U;D2L D1L;D2U D1U;D2U
            originedCoords = [originedLimits(1,1), originedLimits(2,1), originedLimits(1,1),originedLimits(2,1); ...
                              originedLimits(1,2), originedLimits(1,2), originedLimits(2,2),originedLimits(2,2)];
            
            %now we can do the transformation
            scaleMat = [(1/obj.imageScaling(1)),0;0,(1/obj.imageScaling(2))];
                %Scales top row d1 by imageScaling(1)
                %Scales bottom row d2 by imageScaling(2)
            
            scaledCoords = scaleMat * originedCoords;
            revCoords = obj.rotateMatrixDeg(scaledCoords, -obj.imageRotation);

            %so at this point RevCoords represent the CONTINOUS coordiantes
            %of the OUTER coordinates of the area of interest, that now
            %need to be 1) dragged back to a closer to 0 value, and 2
            %translated into 1-endValue space
            
            positveMat = revCoords > 0; % ie. any indiviudal coordinate that should be floored
            revCoords = revCoords + [imgCentre(1);imgCentre(2)]; % now they've been translated

            %this then constrains to a grid back pulling back to the
            %closest centre, theoretically this may lead to slight
            %distortion but its the best possible
            revCoords(positveMat) = floor(revCoords(positveMat));
            revCoords(~positveMat) = ceil(revCoords(~positveMat)); 


        end
        
        function exportToTiledBigTiff(obj, exportLimits, importerDataCell, folder, options)
            % function to coordinate exporting tiled bigTiffs, creates a
            % seperate file for each channel (does so to preserve data
            % types)
            % Expects exportLimits as [d1lower, d2lower; d1upper, d2upper]
            % ImporterDataCell as {ch1_Name, ch1_AIE object, ch1_imgData}
            % folder as the path for the stuff

            % first we need to calculate the size of the image we'll export
            % to do this we calculate first the greatest sf
            arguments
                obj
                exportLimits 
                importerDataCell 
                folder 
                options.tileSize = [4096,4096]
            end


            sfList = cell2mat(cellfun(@(x) 1 ./ x.imageScaling,importerDataCell(:,2),UniformOutput=false));
            maxSF = max(sfList,[],"all");
            

            imageSize = ceil((exportLimits(2,:) - exportLimits(1,:)) * maxSF); %predict size of the image
            %ceil here as imageSize MUST be integer
            %But we now need to calculate the real maxSF
            maxSF = imageSize(1) / (exportLimits(2,1)-exportLimits(1,1)); % we just take 1 dim as it should be the same  

            relativeSFs = maxSF ./ sfList; %calculate the additonal SF we need to increase remaining images by

            %predict datatypes of images
            imagetypes = cellfun(@(x) class(x), importerDataCell(:,3),UniformOutput=false);

            %loop through setting up each image and metadata
            for i = 1:size(importerDataCell,1)
                tiffArr(i) = obj.initaliseTiff(importerDataCell{i,1}, folder, ...
                    imagetypes{i}, imageSize, "tileSize",options.tileSize);
            end

            %now we need to calculate what the tileSize represents on the
            %display space, we ceil it so we're getting overlap rather than
            %anything. Note: tiles are numbered left to right across a row,
            %then down
            tileDimensions = options.tileSize ./ maxSF;
            nTiles = ceil(imageSize ./ options.tileSize);
            

           
            
            %Setup a progress bar so we can watch
            tileCounter = 0;
            totalTiles = nTiles(1) * nTiles(2);
            progressBar = waitbar((tileCounter+1)/totalTiles, "Exporting Images");

            for d1Index = 1:nTiles(1)
                %loop through each yVal (each row)
                
                currentD1Limits = exportLimits(1,1) + [((d1Index-1)*tileDimensions(1));d1Index*tileDimensions(1)]; 
                %note we start these from the start of the export limits

                for d2Index = 1:nTiles(2)
                    tileCounter = tileCounter+1; % updates which tile we're using

                    waitbar(tileCounter/totalTiles, progressBar, strcat("Exporting Images",newline ,"Tile: ", num2str(tileCounter),"/",num2str(totalTiles)));

                    currentD2Limits = exportLimits(1,2)+[((d2Index-1)*tileDimensions(2));d2Index*tileDimensions(2)]; 

                    %loop through each image
                    for imageIdx = 1:length(tiffArr)
                        
                        %get the area we want
                        imageSection = importerDataCell{imageIdx,2}.getAlignedAreaOfInterest( ...
                            importerDataCell{imageIdx,3}, [currentD1Limits, currentD2Limits]);

                        %upscale section if needed
                        %imageSection = imresize(imageSection, relativeSFs(imageIdx));
                        imageSection = imresize(imageSection,options.tileSize);

                        tiffArr(imageIdx).writeEncodedTile(tileCounter, imageSection);
                        
                    end
                end     
            end

            % we should now have everything exported so we can now save
            % stuff
            close(progressBar);
            arrayfun(@(x) x.close(), tiffArr);

        end

    end

    methods(Access=private)

        function tiffObj = initaliseTiff(~, fileRoot,fileDir,dataType,imageSize,options)
            %function to initalise tiffObjects
            arguments
                ~ 
                fileRoot %root name of the file 
                fileDir  %folder
                dataType %encoding of the data eg. uint16
                imageSize %total size of the image
                options.tileSize = [1024,1024] %tile size height, width 
                options.photometric = Tiff.Photometric.MinIsBlack
                options.compression = Tiff.Compression.AdobeDeflate %defaults to lossless based on size

            end
            
            %setup datatype independent tags
            tagStruct.ImageLength = imageSize(1);
            tagStruct.ImageWidth = imageSize(2);
            tagStruct.TileLength = options.tileSize(1);
            tagStruct.TileWidth = options.tileSize(2);
            tagStruct.Photometric = options.photometric;
            tagStruct.Compression = options.compression;

            %setup datatype dependent tags
            switch dataType
                case 'uint8'
                    tagStruct.BitsPerSample = 8;
                    tagStruct.SampleFormat = Tiff.SampleFormat.UInt; %1 - Uint
                case 'uint16'
                    tagStruct.BitsPerSample = 16;
                    tagStruct.SampleFormat = Tiff.SampleFormat.UInt; %1 - Uint
                case 'uint32'
                    tagStruct.BitsPerSample = 32;
                    tagStruct.SampleFormat = Tiff.SampleFormat.UInt;
                case 'uint64'
                    tagStruct.BitsPerSample = 64;
                    tagStruct.SampleFormat = Tiff.SampleFormat.UInt;
                case 'single'
                    tagStruct.BitsPerSample = 32;
                    tagStruct.SampleFormat = Tiff.SampleFormat.IEEEFP; %3 - IEEEFP floats
                case 'double'
                    tagStruct.BitsPerSample = 64;
                    tagStruct.SampleFormat = Tiff.SampleFormat.IEEEFP; %3 - IEEEFP floats
            end

            %initalise object with the tag struct
            tiffObj = Tiff(fullfile(fileDir,strcat(fileRoot,"_aligned.tif")),"w8");
            tiffObj.setTag(tagStruct);
        end

        function clippedImage = clipImage(~, image, clippingMat)
            %function to clip an image by the clipping mat in the form of
            %n to clip for [d1 lower, d2 lower; d1 upper, d2 upper]

            imageSize = size(image);
            newLowers = 1 + clippingMat(1,:);
            newUppers = imageSize - clippingMat(2,:);

            clippedImage = image(newLowers(1):newUppers(1),newLowers(2):newUppers(2));

        end

        function vector = calculateImageToSubImageVector(~, subImageCoords, imageSize)
            %function to calculate the vector between the centre of an
            %image and the centre of an image witihn it
            
            imageCentre = mean([1,1;imageSize]);
            
            subImageCoords = mean(subImageCoords);

            vector = subImageCoords - imageCentre;

        end

        function adjustedOverhangs = proportionallyAdjustOverhangs(~, overhangs, amountToRemove)
            %function to proprotionally trim overhangds
            
            totalOverhangs = sum(overhangs); %get vec of total overhang
            lowerOverhangProp = overhangs(1,:) ./ totalOverhangs; %calculate the proportion of each overhang thats on the lower

            %set nans to 0
            lowerOverhangProp(isnan(lowerOverhangProp)) = 0;

            adjustLower = overhangs(1,:) - (lowerOverhangProp .* amountToRemove);
            adjustUpper = overhangs(2,:) - ((1-lowerOverhangProp) .* amountToRemove);

            adjustedOverhangs = round([adjustLower;adjustUpper]);

        end

        function sideExpansions = caclulateRotationAdditon(~,origianlCoordinates,angle)
            %function to calculate how far an image would expands if
            %rotated through angle theta.

            sideLengths = origianlCoordinates(2,:) - origianlCoordinates(1,:);
            newD1 = abs(cosd(angle)*sideLengths(1)) + abs(sind(angle)*sideLengths(2)); %vertical axis, d1
            newD2 = abs(sind(angle)*sideLengths(1)) + abs(cosd(angle)*sideLengths(2)); %horizontal axis, d2
            sideExpansions = [newD1,newD2] - sideLengths;
        end

        function emptyMat = initaliseSimilarNumericMat(~, exampleClass, size)
            %function to initate an array of zeros of the same class as the
            %image data
            classWanted = class(exampleClass);
            emptyMat = zeros(size,classWanted);
        end
        
        function [imageRotation, imageScale, imageTranslation] = computeGlobalTransformCAT(~,paramStruct)
            %function to translate imported data from crossAlignmentTool to
            %useful shit for this
            %REQUIRED FIELDS
            %  inputSource =  CAT
            %  imageRotation (-180 < x < 180)
            %  imageZoomRatio
            %  mergeScale (don't need for img1, variable if image 2)
            %  imageCentreLoc %Image centre location in coordspace of the
            %  display
            %  imageCentreOffset (note, works opposite to merge offset)
            %                     iirc applies on the displayed image, so
            %                     we need to scale relative to the zoom,
            %                     then also 



            %sort out defaults 
            if ~isfield(paramStruct,"mergeScale")
                paramStruct.mergeScale = 1; % so it doesn't need to be added both times
            end



            %easy, can just take and don't need to do anything
            imageRotation = -paramStruct.imageRotation; 


            %calculate total Zoom, ie. from the merge and from the image
            %Zoom
            imageScale = paramStruct.imageZoomRatio .* paramStruct.mergeScale;

            %now we need to calculate the translation, this is offset by
            %the scale because, we need to go back to the size of the full
            %scale image. This is bascially just taken from my previous
            %code and simplified to a one image nature

            %%% >>> TODO UPDATE TO INCLUDE MERGE SCALE AND IMAGE SCALE AT
            %%% CORRECT POINTS <<<
           
            imageTranslation = paramStruct.imageCentreLoc - paramStruct.imageCentreOffset; 
            
            %imageTranslation = ((-paramStruct.imageCentreOffset .* paramStruct.mergeScale)+paramStruct.mergeOffset).*(1./imageScale);
        end
    
        function rotatedMat = rotateMatrixDeg(~,mat, angleDeg)
            %function to rotate a matrix by an amount of degrees
            %note: it assumes in matlab order, ie. d1 y ontop, d2 x on
            %bottom so the transformation mat is inverted
            rotationRad = deg2rad(angleDeg);
            cosTheta = cos(rotationRad);
            sinTheta = sin(rotationRad);

            transformationMat = [cosTheta,-sinTheta;sinTheta,cosTheta];
            
            %X y inverted
            %transformationMat = [sinTheta,cosTheta; cosTheta, -sinTheta];
            rotatedMat = transformationMat * mat;
        end
    
        function centreCoords = getImageCentre(~,imgData)
            %function to calculate the centre position of an image 
            %returns d1 d2, not rounded
            
            minCoords = [1,1]; %cos matlab weirdly 1 indexes (ew)
            maxCoords = size(imgData);
            centreCoords = (minCoords+maxCoords) ./ 2; 
        end
    
        function imgSectionLimits = getImageSectionLimits(~,idealCoords,maxImageSize)
            
            %get the extent of the image
            imgSectionLimits = [min(idealCoords(1,:)),min(idealCoords(2,:)); ...
                                max(idealCoords(1,:)), max(idealCoords(2,:))];


        end

        function [imgSectionLimits,sideOverhang] = expandToSectionLimits(~,idealCoords,maxImageSize)
            %function to expand a set of non-grid aligned coords to limits
            %on the actual grid so and image can be extracted. 
            %note coords are in matrix form ie.
            % d1_1 d1_2 d1_3
            % d2_1 d2_2 d1_3



            imgSectionLimits = [min(idealCoords(1,:)),min(idealCoords(2,:)); ...
                                max(idealCoords(1,:)), max(idealCoords(2,:))];
            

            % maxD1 = max(idealCoords(2,:));
            % maxD2 = max(idealCoords(1,:));
            % minD1 = min(idealCoords(2,:));
            % minD2 = min(idealCoords(1,:));

            %Now we're going to validate they're not outside the image
            %limits, and where they are we're gonna push the difference
            %into side overhangs 

            MinOverlaps = 1 - imgSectionLimits(1,:);
            MinOverlaps(MinOverlaps <= 0) = 0; %negative ones imply they're fine and inside
            imgSectionLimits(1,MinOverlaps ~= 0) = 1; %so where things aren't 0 there's an overlap so we need to limit down to 1 to prevent overflow


            %same here but overflow is based on variable image uppeer limit
            MaxOverlaps = imgSectionLimits(2,:) - maxImageSize; 
            MaxOverlaps(MaxOverlaps <= 0) = 0;
            if MaxOverlaps(1) ~= 0
                imgSectionLimits(2,1) = maxImageSize(1);
            end
            if MaxOverlaps(2) ~= 0
                imgSectionLimits(2,2) = maxImageSize(2);
            end
            
            sideOverhang = [MinOverlaps;MaxOverlaps];
        end

        function scaleVec = getMinimumResScalingScale(~, scaleFactor)
            %function to return the scaling needed so that the image is
            %only expanded not contracted  ie. so we scale bigger and don't
            %lose detail

            minScaling = min(scaleFactor,[],"all");
            if minScaling < 1
                sf = 1/minScaling;
                scaleVec = scaleFactor .* sf;
            else
                %we're already not having to scale as its already the right
                %size and adding more is smth we can do later#

                % >>> might need to just be 1,1 or the og  - not sure, maybe cos at
                % that point I'd expect 
                scaleVec = [1,1]; 
            end


        
        end

    end

end
