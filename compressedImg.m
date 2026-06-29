classdef compressedImg < handle
    %compressedImg class - stores an image and a downscaled copy then
    %handles transformations of that to allow fast rendering and moving w/o
    %compromising image quality

    properties (Access=private)
        imgPath
        imgName
        fullScaleImgData %Cell array of image matricies
        downScaleImgData %Cell array of downscaled image matricies
        tfDownScaleImgData %Cell array of downscaled image data after transformations
        maxResolution %[d1 d2] values for max resolution in the downscaled
        imgBitDepth %value for bitdepth of orignal image
        nativeResolution %[ ] values for x and y dimentions
        exportResolution %[d1 d2] values for resolution to be exported, equal to initial maxRes
        isInverted %bool inverts in y axis -> note we only have one way to do this as w/ rotation its identical
        currentRotation = 0 %values in deg between -180 to +180
        currentZoom = 1 
        centreLimits %[mind1, mind2; max1,max2]
        maxZoom %maximum value for amount of zoom possible = nativeResolution./exportResolution
        nSlices
        displayedSlice
        minIntensity
        maxIntensity
        imageMetadataDescription %Description from image
        readyToDisplay = false%bool which states if the 
    end

    %Events that can be reacted to by UI
    events
        %zoomChanged %event notifying the zoom changed, to be used for GUI to update limits for centre positions
    end

    methods (Access=public)
        function obj = compressedImg(imageLoc,imageName, inputMaxResolution)
            %Generate a downscaled image handler
            %imagePath - path for the image to be loaded
            %targetResolution - the size to downscale the image to

            obj.readyToDisplay = false;
            
            %populate parameters
            obj.imgName = imageName;
            obj.imgPath = strcat(imageLoc,imageName);


            obj.maxResolution = inputMaxResolution;
            obj.exportResolution = inputMaxResolution;
            
            %load the image
            obj.loadTiff();            

        end

        %function to output image name
        function imgName = getImgName(obj)
            imgName = obj.imgName;
            return 
        end

        function fsImgData = getFullScaleImgData(obj)
            %inverts the data if needed
            if obj.isInverted
                fsImgData = obj.invertImgData(obj.fullScaleImgData);
            else
                fsImgData = obj.fullScaleImgData;
            end
        end

        %function to get img controls metadata, returns as a struct
        function metadata = getImgControlsMetadata(obj)
            %initalise
            metadata = struct();
            
            metadata.zMax = obj.nSlices;
            metadata.minIntensity = double(obj.minIntensity);
            metadata.maxIntensity = double(obj.maxIntensity);
            metadata.maxZoom = obj.maxZoom;
            metadata.centreLimits = obj.centreLimits;
        end

        %function to get specifically the centreLimits
        function centreLimits = getCentreLimits(obj)
            centreLimits = obj.centreLimits;
        end

        %function to set maxResolution, can be either a sqr value or [x y]
        function setMaxRes(obj, maxResolution)
            
            if size(maxResolution,2) == 1
                obj.maxResolution = [maxResolution, maxResolution];
            else
                obj.maxResolution = maxResolution;
            end
        end

        function setInvert(obj, invert)
            obj.isInverted = invert;
        end

        function isInverted = getIsInverted(obj)
            isInverted = obj.isInverted;
        end
        %function to invert an image
        function outputImgData = invertImgData(obj,imgData)
            
            outputImgData = cell(1,obj.nSlices);

            for i = 1:obj.nSlices
                outputImgData{i} = flip(imgData{i});
            end
        end

        %function to initate downscaling -> newMaxRes is optional
        %returns 1 if zoomed, 0 if at maxZoom
        %this also handles updating rotation if needed via calling the
        %rotate thingy
        function state = generateDownScaleImage(obj, zoom)

            if exist("zoom","var")
                %we need to change the zoom
                %so lets first change the maxRes note this applies to both

                %make sure maxResolution < native resolution
                testResolution = obj.exportResolution * zoom;

                if any((testResolution > obj.nativeResolution))
                    obj.maxResolution = obj.nativeResolution; %if its too big replace it w/ native
                    state = 0;
                else
                    obj.maxResolution = testResolution; %otherwise use normal
                    state = 1;
                end
            end


            obj.readyToDisplay = false;
            obj.populateDownscaled(); %this does the doewn scaling

            %invert if needed
            if obj.isInverted
                obj.downScaleImgData = obj.invertImgData(obj.downScaleImgData);
            end

            %update to confirm rotation
            obj.currentRotation = 0; %as images will be unrotated
            obj.rotateDownScaleImage(0); %recalculate rotation

            if exist("zoom","var")
                obj.currentZoom = zoom; %just to update this if we changed anything
                %notify(obj, zoomChanged)
            end

            %update bounds for the centre
            obj.centreLimits = obj.updateCentreBounds();
            

            obj.readyToDisplay = true;

            %disp("downscale succesful");
        end

        %function to check if the image is all good
        function rtd = getReadyToDisplay(obj)
            rtd = obj.readyToDisplay;
        end

        %function to rotatedownscale image (Note: this will likely be
        %somewhat successively destructive) but this makes more sense than
        %storing a whole extra set of data -> she says lol, seriously
        %though any time you change szoom this'll be recalled so it'll be
        %refershed.
        function obj = rotateDownScaleImage(obj, angleToRotate)
            %first we need to calculate the angle to rotate

            obj.readyToDisplay = false; %halt displaying until sorted

            %now we just loop through the various images and rotate them
            %all by the angle?

            obj.tfDownScaleImgData = cell(1,length(obj.downScaleImgData));
            %toRotate = obj.cropImgStack(obj.downScaleImgData);
            toRotate = obj.downScaleImgData;
            if obj.nSlices > 1
                for i = 1:obj.nSlices
    
                    currSlice = toRotate{i};
                    rotatedSlice = imrotate(currSlice,-angleToRotate);

                    if any(size(rotatedSlice) < obj.maxResolution)
                        obj.tfDownScaleImgData{i} = obj.bufferRotatedSlice(rotatedSlice);
                    else %don't need to compensate
                        obj.tfDownScaleImgData{i} = rotatedSlice;
                    end
                end
            else
                currSlice = toRotate{1};
                rotatedSlice = imrotate(currSlice,-angleToRotate);

                if any(size(rotatedSlice) < obj.maxResolution)
                        obj.tfDownScaleImgData{1} = obj.bufferRotatedSlice(rotatedSlice);
                else %don't need to compensate
                        obj.tfDownScaleImgData{1} = rotatedSlice;
                end

                i = 1; % just to sort out for later ie. updating max res
            end
            obj.currentRotation = angleToRotate; %update with where we are now

            %crop downscale 
            %obj.downScaleImgData = obj.cropImgStack(obj.downScaleImgData, obj.exportResolution);
            %update max res with the new image resolution

            % >>> CHECK THIS AS THIS FEELS CIRCULAR
            obj.maxResolution = size(obj.tfDownScaleImgData{i});

            obj.readyToDisplay = true;
        end


        %function to output a the requested image plane
        function imgMat = requestImg(obj, options)
            arguments
                obj 
                options.zPlane = 1 %alters the Z plane rendered
                options.centre_1 = 0 %alters centre when zoomed in axis1
                options.centre_2 = 0 %alters centre when zoomed in axis2
            end

            if obj.readyToDisplay == false
                imgMat = [];
                return
            end

            if obj.nSlices > 1
                imgMat = obj.getCentredImg(obj.tfDownScaleImgData{options.zPlane}, ...
                    options.centre_1,options.centre_2);
            else
                %it won't be a cell for some fucking reason dk why bit
                %annoying that it tries to be a smort boi
                imgMat = obj.getCentredImg(obj.tfDownScaleImgData{1}, ...
                    options.centre_1,options.centre_2);
            end
        end
       
        
        %function to output currentZoom
        function currentZoom = getCurrentZoom(obj)
            currentZoom = obj.currentZoom;
        end

        %function to output the zoom ratio, ie. how much of a displayed
        %pixel a native pixel is
        function zoomRatio = getZoomRatio(obj)
            zoomRatio = obj.currentZoom ./ obj.maxZoom;
        end

        %function to output key data from the inital image
        function metadata = getNativeImgMetaData(obj)
            metadata = struct();
            metadata.maxIntensity = obj.maxIntensity;
            metadata.minIntensity = obj.minIntensity;
            metadata.bitDepth = obj.imgBitDepth;
        end
    end

    methods (Access=private)
        function loadTiff(obj)
            %function to load the tiff into the data
            %disp(obj.imgPath);
            %note: data assumes 0 colour channels ie its all one greyscale
            tiffData = tiffreadVolume(obj.imgPath);
            obj.nSlices = size(tiffData,3);

            %grab the metadata struct
            tiffMetadata = imfinfo(obj.imgPath);
            if isfield(tiffMetadata,"ImageDescription")
                obj.imageMetadataDescription = tiffMetadata.ImageDescription;
            else
                obj.imageMetadataDescription = "";
            end

            %get min and max values 
            %note: we use the values from the data so we don't get fucked
            %around by the min and max of the datatype ie uint(BITS)
            %obj.minIntensity = tiffMetadata.MinSampleValue;
            %obj.maxIntensity = tiffMetadata.MaxSampleValue;
            obj.minIntensity = min(tiffData,[],"all");
            obj.maxIntensity = max(tiffData,[],"all");

            %get bit depth -> important for export
            obj.imgBitDepth = tiffMetadata.BitDepth;

            %get resolution values
            calcResolution = zeros(1,2);
            calcResolution(1) = size(tiffData,1);
            calcResolution(2) = size(tiffData,2);
            obj.nativeResolution = calcResolution;
            obj.maxZoom = obj.nativeResolution./obj.exportResolution; %note: this is in both dimensions and is a double, so min before use as an int
            if any(obj.maxZoom <= 1) %less than or equal to prevent any random bs w/ float maths 
                obj.maxZoom = [1,1];
            end

            %preallocate cell
            obj.fullScaleImgData = cell(obj.nSlices,1);
            
            %generate progress dialog
            fig = uifigure;
            d = uiprogressdlg(fig, 'Title',"Please wait, importing data", ...
                'Message',"Prepareing Import");
            
            %loop through all the slices to add each image slice
            %to its position in the image data
            for currSlice = 1:obj.nSlices
                d.Value = currSlice/(obj.nSlices+1);
                d.Message = strcat("Loading Slice: ", num2str(currSlice), ...
                    " of ", num2str(obj.nSlices));
                currSliceData = tiffData(:,:,currSlice);
                obj.fullScaleImgData{currSlice,1} = currSliceData;
            end

            %close dialog now we're done
            close(fig)
        end

        %function to calculate the needed scalefactor to drop the
        %resolution below max
        %returns the multiple times smaller the image needs to be ie
        % 1000 -> 500 would be 2x
        function [sf, axis]= calculateScaleFactor(obj)

            %calc x and y
            xScaleFactor = obj.nativeResolution(1)/obj.maxResolution(1);
            yScaleFactor = obj.nativeResolution(2)/obj.maxResolution(2);
            
            %pick the biggest
            if xScaleFactor > yScaleFactor
                sf = xScaleFactor;
                axis = 1;
            else
                sf = yScaleFactor;
                axis = 2;
            end
            return

        end
        
        %function to calulate the indexes of the data to be replaced by 
        %the downscaled image, essentially tries to centre it on the other
        function [lower, upper] = centreSubAxis(~, majorRange,minorRange)
            
            sideExcess = (majorRange - minorRange)/2;
            lower = 1+round(sideExcess,"TieBreaker","plusinf"); %note: 1 indexed and inclusive both sides
            upper = majorRange-round(sideExcess,"TieBreaker","minusinf");

        end

        %Function to calculate the downscaled version of the image
        function obj = populateDownscaled(obj)
            
            %first lets work out if we need to downscale by calculating the
            %scaling multiplier
            [scaleFac, domAxis] = obj.calculateScaleFactor();

            
            %preallocate downscaleimgdata
            obj.downScaleImgData = cell(1,obj.nSlices);
            
            %loop through each slice
            for currSlice = 1:obj.nSlices
                %precondition imgArr
                ImgArr = zeros(obj.maxResolution(1),obj.maxResolution(2));
                
                currSource = obj.fullScaleImgData{currSlice};
                %if we need to resize
                if scaleFac > 1
                    %Note we resize by number of columns to make sure we
                    %don't get rounding errors causing image
                    %desyncs/overflows

                    if domAxis == 1
                        currSource = imresize(currSource,[obj.maxResolution(1),NaN]);
                    else
                        currSource = imresize(currSource,[NaN, obj.maxResolution(2)]);
                    end
                    %note: we only give one based on what the limiting
                    %thing is so we don't distort the image

                    
                end
                %centre on imageArr flanked by 0s
                [Lower1, Upper1] = obj.centreSubAxis(obj.maxResolution(1),size(currSource,1));
                [Lower2, Upper2] = obj.centreSubAxis(obj.maxResolution(2),size(currSource,2));
                    
                ImgArr(Lower1:Upper1,Lower2:Upper2) = currSource;
                obj.downScaleImgData{currSlice} = ImgArr; %assign ImgArr to the downscaled image
            end 
               
        end

        %function to get a centred image, handles for if zoom >1
        function imgArr = getCentredImg(obj,imgData, centre1,centre2)
            if obj.currentZoom == 1
                %we don't need to do any picking of a part of the image
                imgArr = imgData;
                return
            end

            %otherwise we need to select an area the size of the thingy
            %from within, luckily this is what the centre sub axis does
            %cos then we can just take those and displace by centre
            [lower_1,upper_1] = obj.centreSubAxis(obj.maxResolution(1),obj.exportResolution(1));
            [lower_2,upper_2] = obj.centreSubAxis(obj.maxResolution(2),obj.exportResolution(2));

            %now we displace these by centre
            lower_1 = lower_1 + centre1;
            upper_1 = upper_1 + centre1;

            lower_2 = lower_2 + centre2;
            upper_2 = upper_2 + centre2;

            %note: will protect these from overflow via the centre metadata
            imgArr = imgData(lower_1:upper_1,lower_2:upper_2);
            
        end

        %function to get the size of the currently exported image
        function imgSize = getCurrentExportImageSize(obj)
            imgSize = size(obj.tfDownScaleImgData{1});
        end

        %function to get bounds of where the centre can exist
        %[mind1, mind2; maxd1,max2]
        function centreBounds = updateCentreBounds(obj)
            
            %precondition
            centreBounds = zeros(2);
            fullImageSize = obj.getCurrentExportImageSize();
            exportResolution = obj.exportResolution();

            %loop through dimensions
            for i = 1:2 
                if fullImageSize(i) == exportResolution(i)
                    %shortcut cos we can't move in this dimension
                    centreBounds(:,i) = [0;0];
                else
                    maxShift = floor((fullImageSize(i)-exportResolution(i))/2);
                    %round down to prevent issues 

                    centreBounds(:,i) = [1-maxShift; 0+maxShift];

                    %we need to do work
                    %cos its symmetrical we will work out how far we can go
                    %on each side and then add/subtract from 0
                end
            end
        end
        
        %function to crop blackspace out of an image
        %has an option to specify min image dimensions
        function croppedImgStack = cropImgStack(~,imgCell,minDims)
            arguments
                ~ 
                imgCell 
                minDims = [1,1] %default settings, can cut as close as you like
            end

            %first we're gonna convert the cell into a 3d arr
            nImages = length(imgCell);
            imageSize = size(imgCell{1});
            imgMat = zeros([imageSize,nImages]); %precondition
            for i = 1:nImages
                imgMat(:,:,i) = imgCell{i};
            end

            imgBounds = zeros(2); %2x2 arr [minD1, minD2;maxD1, maxD2];

            %now we're going to cut through each dimension in slices to
            %stop when we find anything
            for dim = 1:2
                %loop from min to max
                for minIdx = 1:imageSize(dim)
                    %get current slice
                    if dim == 1
                        currImgSlice = imgMat(minIdx,:,:);
                    else
                        currImgSlice = imgMat(:,minIdx,:);
                    end
                    
                    if ~all(all(currImgSlice==0)) %weirdly we need to double all this otherwise it just does it in one dimension returning an arr
                        %we've found image, break
                        break
                    end
                end

                %loop from max to min
                for maxIdx = imageSize(dim):-1:1
                    %get current slice
                    if dim == 1
                        currImgSlice = imgMat(maxIdx,:,:);
                    else
                        currImgSlice = imgMat(:,maxIdx,:);
                    end
                    
                    if ~all(all(currImgSlice==0))
                        %we've found image, break
                        break
                    end
                end
                
                %check vs min size
                if ((maxIdx-minIdx)+1) < minDims(dim)
                    %calculate size around centre based on minimum
                    centrePos = imageSize(dim)/2;
                    minRad = minDims(dim)/2;
                    imgBounds(:,dim) = ceil([centrePos-minRad;centrePos+minRad])+[1;0]; %+1;0 to compensate for inclusive 1 idx
                else
                    %slap in the min and maxIdx
                    imgBounds(:,dim) = [minIdx;maxIdx];
                end
            end

            croppedMat = imgMat(imgBounds(1,1):imgBounds(2,1),imgBounds(1,2):imgBounds(2,2),:);
            
            %now put this back into a cell
            croppedImgStack = cell(1,nImages);
            for i = 1:nImages
                croppedImgStack{i} = croppedMat(:,:,i);
            end
        end

        function bufferedSlice = bufferRotatedSlice(obj, slice)
            %function to buffewr smaller than max res slices when rotated
            sliceSize = size(slice);

            [d1Lower, d1Upper] = obj.centreSubAxis(obj.maxResolution(1),sliceSize(1));
            [d2Lower, d2Upper] = obj.centreSubAxis(obj.maxResolution(2),sliceSize(2));

            bufferedSlice = zeros(obj.maxResolution(1),obj.maxResolution(2));
            bufferedSlice(d1Lower:d1Upper,d2Lower:d2Upper) = slice;
        end
    end


end