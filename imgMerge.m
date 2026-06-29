classdef imgMerge < handle
    %Class to handle merging two different images
    %Also supports translation across each other
    %Note: doesn't do any funky image manipulation, that's pulled 
    %from the compressed image class stuff from the other shit
    properties
        overlayedImage
        img1Loc
        img2Loc
        currentOffset
        currentScale
        img1_8bit
        img2_8bit
        img1Invert
        img2Invert
        img1Contrast
        img2Contrast
    end

    methods (Access=public)

        %constructor 
        function obj = imgMerge(img1,img2,options)
            arguments
                img1 %first image (shown in red)
                img2 %second image (shown in green)
                options.img1Invert = false %inverts white/black hot
                options.img2Invert = false
                options.img1Contrast (1,2) % [lower contrast, upper contrast]
                options.img2Contrast (1,2) % [lower contrast, upper contrast]
                options.offset_x = 0; % relative x translation
                options.offset_y = 0; % relative y translation
                options.scale_x = 1; % relative x scale
                options.scale_y = 1; % relative y scale
                
            end
            
            %right so with each image we need to convert to 255 bit images
            %based on the contrast 
            obj.img1_8bit = obj.imgTo8bit(img1, options.img1Contrast);
            obj.img2_8bit = obj.imgTo8bit(img2, options.img2Contrast);

            %now we have the 8bit images, we need to overlay them as two
            %different channels 
            obj.currentOffset = [options.offset_y,options.offset_x];
            obj.currentScale = [options.scale_y,options.scale_x];
            obj.img1Contrast = options.img1Contrast;
            obj.img2Contrast = options.img2Contrast;
            obj.overlayedImage = obj.genOverlapedImages(obj.img1_8bit,obj.img2_8bit, ...
                "offset",obj.currentOffset,"scale",obj.currentScale);
        end


        %function to refresh if we need to regenerate the 8bit images
        %this occurs if contrasting changes or if the images are changed in
        %anyway
        function obj = updateImage(obj, img, imgNo, contrast)
            
            %if no contrast specified take the contrast from the obj
            if ~exist("contrast","var")
                if imgNo == 1
                    contrast = obj.img1Contrast;
                else
                    contrast = obj.img2Contrast;
                end
            end

            % generate new 8bit images

            if imgNo == 1
                obj.img1Contrast = contrast;
                obj.img1_8bit = obj.imgTo8bit(img,contrast);
            else
                obj.img2Contrast = contrast;
                obj.img2_8bit = obj.imgTo8bit(img,contrast);
            end

            %refresh the image
            obj.overlayedImage = obj.genOverlapedImages(obj.img1_8bit, obj.img2_8bit, ...
                "offset",obj.currentOffset, "scale", obj.currentScale);
        end
    
        %get function to grab property externally
        function img = getOverlayedImage(obj)
            img = obj.overlayedImage;
        end

        %function to change the scale of the image#
        %don't do anything to the offset so its reliable
        function obj = rescaleImage(obj, newScale)
            newOffset = obj.currentOffset; %.* (newScale./obj.currentScale);
            
            obj.overlayedImage = obj.genOverlapedImages(obj.img1_8bit,obj.img2_8bit,...
                "img1Invert",obj.img1Invert, "img2Invert",obj.img2Invert, ...
                "offset", newOffset, "scale", newScale);
            obj.currentOffset = newOffset;
            obj.currentScale = newScale;
        end

        %Attempt 2 at a more robust translate image function
        function obj = translateImage(obj, newOffset)
            
            img1Centre = mean(obj.img1Loc,2); %find the mean dim 1 and 2 pos
            img2NewCentre = img1Centre + transpose(newOffset); %offset img2's centre

            %now we will calculate the image bounds from their centres
            img2TempLoc = obj.updateBoundsFromCentre(img2NewCentre, obj.img2Loc);

            %now we need to check where the minimum values sit
            %ie: can we cut some of the image off at the end
            %  : do we need to shift our values right to avoid overflow
            
            %this gives the min values as a vector
            minValues = min([img2TempLoc(:,1), obj.img1Loc(:,1)],[],2);

            %note: if we need to displace img1's coord system
            globalShift = [0;0];

            if minValues(1) < 1
                globalShift(1) = 1 - minValues(1);
            end
            if minValues(2) <1
                globalShift(2) = 1 - minValues(2);
            end

            %do we need to expand the grid
            maxValues = max([img2TempLoc(:,2), obj.img1Loc(:,2)],[],2);
            
            %make quick adjustment to compensate for global shift
            minValues = minValues + globalShift;
            maxValues = maxValues + globalShift;

            %back to working out if we need to expand the grid
            gridSize = size(obj.overlayedImage);

            gridExpansion = [0;0];
            if maxValues(1) > gridSize(1)
                gridExpansion(1) = maxValues(1) - gridSize(1);
            end
            if maxValues(2) > gridSize(2)
                gridExpansion(2) = maxValues(2) - gridSize(2);
            end


            tempImg = obj.overlayedImage;
            %if we need to expand the grid
            if any(gridExpansion ~= 0)
                tempImg = obj.expandImgMat(tempImg, gridExpansion);
            end

            %Now we've expanded the grid, we now need to translate
            %Img1 will only need to move by global shift as we can assume
            %it was previously in area bounded by the image
            %Img 2 will move by sum of old center to new center and global
            %shift

            if any(globalShift ~= 0)
                tempImg(:,:,1) = circshift(tempImg(:,:,1),transpose(globalShift));
            end
            
            %calculate the amount we need to move (size hasn't changed to
            %min or max values should be the same
            img2Shift = transpose(img2TempLoc(:,1) - obj.img2Loc(:,1));
            tempImg(:,:,2) = circshift(tempImg(:,:,2),(img2Shift+transpose(globalShift)));
            
            %grids are now translated, so all we need to do now is clean
            %the grid size and then calculate the new imgLocs

            %set the overlayed image to just the region occupied by the
            %images
            obj.overlayedImage = tempImg(minValues(1):maxValues(1),minValues(2):maxValues(2),:);

            %now we need to update bounds so they represent the new
            %positions
            obj.img1Loc = obj.img1Loc + globalShift - minValues + 1;
            obj.img2Loc = img2TempLoc + globalShift - minValues + 1;
            obj.currentOffset = newOffset;
             
        end



        %OLD TRANSLATE FUNCTION
        % function obj = translateImage(obj, newOffset)
        %     %right so we're gonna extract the location of the image in img2
        %     relativeOffset = newOffset - obj.currentOffset;
        % 
        %     %now we need to work out if we're going to leave the bounds of
        %     %the current thingy 
        %     imageSize = size(obj.overlayedImage);
        %     newImg2Loc = obj.calcShiftedImgLoc(obj.img2Loc,relativeOffset);
        %     overhangs = obj.calculateOverhang(newImg2Loc, imageSize);
        %     img = obj.overlayedImage;
        % 
        %     if sum(overhangs,"all") ~= 0
        %         %we need to add space to the data
        %         img1Offset = [0,0];
        % 
        %         %if first dim is overlapping under
        %         if overhangs(1,1) > 0
        %             extraData = zeros([overhangs(1,1),imageSize(2),3]);
        %             img = [extraData;img];
        %             img1Offset(1) = overhangs(1,1); %note: these are positive becuase we're shoving the other way
        %             imageSize = size(img);
        %         end
        % 
        %         %if second dim is overlapping under
        %         if overhangs(2,1) > 0
        %             extraData = zeros([imageSize(1),overhangs(2,1),3]);
        %             img = [extraData,img];
        %             img1Offset(2) = overhangs(2,1);
        %             imageSize = size(img);
        %         end
        % 
        %         %if first dim is overlapping over
        %         if overhangs(1,2) > 0
        %             extraData = zeros([overhangs(1,2),imageSize(2),3]);
        %             img = [img; extraData];
        %             imageSize = size(img);
        %         end
        % 
        %         %if the second dim is overlapping over
        %         if overhangs(2,2) > 0
        %             extraData = zeros([imageSize(1),overhangs(2,2),3]);
        %             img = [img, extraData];
        %             %imageSize = size(img); %don't need to update image
        %             %size anymore
        %         end
        % 
        %         %this measures the amount img1 has moved from the addition
        %         %of data
        %         if sum(img1Offset) ~= 0
        %             newimg1Loc = obj.img1Loc + transpose(img1Offset); 
        %             %transpose it into a vertical matrix
        %             %that way each dim adds to the same dim
        %         else
        %             newimg1Loc = obj.img1Loc;
        %         end
        % 
        % 
        % 
        %     end
        % 
        %     %now we move the second image
        %     img(:,:,2) = circshift(img(:,:,2),relativeOffset);
        %     obj.currentOffset = newOffset;
        % 
        %     %At this point we need to tidy things up to crop black-space
        %     cropStruct = obj.cropBlackSpace(img);
        % 
        %     %Now we need to calculate where this puts the imgLocs
        %     cropStruct.dataStartMat(1,:) = cropStruct.dataStartMat(1,:) -1;
        %     %thus we account for it being one indexed
        % 
        %     obj.img1Loc = newimg1Loc - cropStruct.dataStartMat(1,:);
        %     obj.img2Loc = newImg2Loc - cropStruct.dataStartMat(1,:);
        %     %subtracting cropStruct.dataStart(1,:) removes any amount that
        %     %was cut off from the start
        % 
        %     obj.overlayedImage = cropStruct.img;
        % end
        
        function overlayedSize = getOverlayedSize(obj)
            %function to return the 2d size of the image
            imgSize = size(obj.overlayedImage);
            overlayedSize = [imgSize(1),imgSize(2)];
        end

    end

    methods (Access=private)

        %function to calculate the image location after being shifted 
        function imgLoc = calcShiftedImgLoc(~, imgLoc, offset)
            %unpack into the seperate dimensions and for each add to the
            %lower bounds
            newBounds_1 = imgLoc(1,:)+offset(1);
            newBounds_2 = imgLoc(2,:)+offset(2);
            imgLoc = [newBounds_1; newBounds_2]; %repackacge
        end


        %function to calculate how much a shifted image would overhang from
        %the inital
        %returns mat, values represent absolute overhang
        % [ dim 1 lower, dim 1 upper]
        % [ dim 2 lower, dim 2 upper]
        function overhang = calculateOverhang(~, shiftedLoc,coordSize)
            
            %lower vals
            if (shiftedLoc(1,1) < 1)
                lowerOverhang_1 = 1 - shiftedLoc(1,1); 
            else
                lowerOverhang_1 = 0;
            end

            if (shiftedLoc(2,1) < 1)
                lowerOverhang_2 = 1 - shiftedLoc(2,1); 
            else
                lowerOverhang_2 = 0;
            end
            
            %upper vals
            if (shiftedLoc(1,2) > coordSize(1))
                upperOverhang_1 = shiftedLoc(1,2) - coordSize(1);
            else
                upperOverhang_1 = 0;
            end

            if (shiftedLoc(2,2) > coordSize(2))
                upperOverhang_2 = shiftedLoc(2,2) - coordSize(2);
            else
                upperOverhang_2 = 0;
            end

            overhang = [lowerOverhang_1, upperOverhang_1; lowerOverhang_2, upperOverhang_2];

        end

        %function to rescale and image
        function scaledImg = rescaleImg(~, img, scale)
            currentSize = size(img);
            targetSize = round(currentSize.*scale); %note round it cos we can't do like 
            scaledImg = imresize(img,targetSize);
        end

        %function to calculate how big the image resultant image will be
        %when two are overlapped. Also gives an offset multiplier based on
        %which is fully enclosed -> allows nice short cutting with the same
        %logic

        %note: we use 2x offset, as we want to compare the one sided
        %overlap of offset+halfI1 vs halfI2, so to reduce computation can
        %just double the offset
        function [imgSize, offsetMultiplier] = calcMergeSize(~, img1Size, img2Size, offset)
            %if one image is entirely within another we can just use the
            %bigger image
            nDims = length(img1Size);
            imgSize = zeros(1,nDims);

            for i = 1:nDims
                if (img2Size(i)+abs(offset(i)*2)) <= img1Size(i)
                    %img 2 is contained by img 1
                    imgSize(i) = img1Size(i);

                    offsetMultiplier = [0,1]; % ie. 2 is to be moved, and 1 is static
                elseif (img1Size(i)+abs(offset(i)*2)) <= img2Size(i)
                    %img 1 is contained by img 2
                    imgSize(i) = img2Size(i);

                    offsetMultiplier = [1,0]; %ie. 1 is to be moevd, 2 is static
                else
                    imgSize(i) = ((img1Size(i) + img2Size(i))/2) + abs(offset(i));
                    offsetMultiplier = [0.5,0.5]; %ie we split the offset between them
                    %images have their own space, thus the length is equal
                    %to half the size of img1, + the distance between
                    %centres + half the size of img 2
                end
            end
            imgSize = ceil(imgSize); % to prevent halfs coming through, we ceil so we don't exceed the lower limit ie 1
        end

        %function to calculate where an image should be positioned on
        %a larger coordinate system based on an offset from centre
        function bounds = calcImgPos(~,destSize, inputSize, offset)

            if ~exist("offset","var")
                offset = 0;
            end

            %OLD NOW ACHIEVED AT THE LEVEL ABOVE
            % if destSize == inputSize
            %     %shortcut if one entirely contains the other
            %     bounds = [1, inputSize];
            %     return
            % end
        
            %find the centre of the larger system
            destCentre = round(destSize/2,"TieBreaker","tozero");
            
            %find the "radius" of the input size
            inputRad = round(inputSize/2,"TieBreaker","tozero");

            %adding 1 cos its one indexed
            lowerBound = offset+destCentre-inputRad+1;
            upperBound = lowerBound+inputSize-1;
            %subtracting one as 1 and the last val are both vals
            %note: we calc this to make sure we don't round off a line of 
            %data

            bounds = [lowerBound,upperBound];    
        end

        %function to convert 2images into a 2image RGB image
        %note: img2 is position wrt to img2
        function overlappedImages = genOverlapedImages(obj,img1,img2,options)
            arguments
                obj
                img1 
                img2 
                options.offsets (1,2) % [x, y]
                options.scale (1,2) % [x, y]
                options.img1Invert = false;
                options.img2Invert = false;
            end


            
            if isempty(options.scale)
                options.scale = [1,1];
            else
                img2 = obj.rescaleImg(img2,options.scale);
            end

            %so at the points images will be nicely setup and we're just
            %slapping one ontop of each other


            %right so actually here lets look at working out the
            %translation stuff so we're not cutting off images but just
            %chnaging where we draw it, so we just need to work out where
            %bits place relative to each other 
            
            %set default offsets if needed
            if isempty(options.offsets)
                options.offsets = [0,0];
            end
            
            %precondition image array

            %Size is calculated from the max dimesions of img1 and img2
            %(post translation)
            img1size = size(img1);
            img2size = size(img2);
            [arrSize, offsetMultiplier] = obj.calcMergeSize(img1size,img2size,options.offsets);
            %offset multiplier is a 2 value vec which encodes how much of
            %the offset should be pushed into each image

            %precondition with x3 in last dimension for RGB
            overlappedImages = zeros([arrSize(1),arrSize(2),3]); 
            
            %now we calculate image positions
            %Note: in future make these a 2x2 mat for each, its much easier
            %to work with
            img1Offsets = options.offsets .* offsetMultiplier(1);
            img1_1Bounds = obj.calcImgPos(arrSize(1),img1size(1),-img1Offsets(1));
            img1_2Bounds = obj.calcImgPos(arrSize(2),img1size(2),-img1Offsets(2));
            
            img2Offsets = options.offsets .* offsetMultiplier(2);
            img2_1Bounds = obj.calcImgPos(arrSize(1),img2size(1), img2Offsets(1));
            img2_2Bounds = obj.calcImgPos(arrSize(2),img2size(2), img2Offsets(2));
            
            %fron this we need to check if anything is going to overflow
            %and if we need to adjust, should be able to just do this on
            %one side
            minVals = [min([img1_1Bounds(1),img2_1Bounds(1)]), min([img1_2Bounds(1),img2_2Bounds(1)])];
            
            %minVals we want to set to 1, thus 
            if ~all(minVals == 1)
                adjustment = [1,1] - minVals;
                img1_1Bounds = img1_1Bounds + adjustment(1);
                img2_1Bounds = img2_1Bounds + adjustment(1);
                img1_2Bounds = img1_2Bounds + adjustment(2);
                img2_2Bounds = img2_2Bounds + adjustment(2);
            end

            overlappedImages(img1_1Bounds(1):img1_1Bounds(2),img1_2Bounds(1):img1_2Bounds(2),1) =...
                img1;
            overlappedImages(img2_1Bounds(1):img2_1Bounds(2),img2_2Bounds(1):img2_2Bounds(2),2) =...
                img2;
            
            obj.img1Loc = [img1_1Bounds; img1_2Bounds];
            obj.img2Loc = [img2_1Bounds; img2_2Bounds]; 
            %record this in the object just incase we need to do anything
            %quickly

            %right image should now be nicely placed and translated

            %could put a cleanup stage here to make sure its nicely
            %together
        end
        


        %function to convert an image to an 8bit image based on the
        %min and max values or provided contrast values
        function outputImg = imgTo8bit(~, inputImg, contrast)
            if ~exist("contrast","var") || isempty(contrast)
                %if contrast was not passed then we're gonna have to calculate it
                contrast = [min(inputImg,"all"),max(inputImg,"all")];
            end
            
            %now we convert it to 8bit values
            workingImg = inputImg - contrast(1); %subtract minimum value
            scaleFactor = 1/(contrast(2)-contrast(1)); %calculated before to minimise calculations
            workingImg = workingImg * scaleFactor; %this then puts onto a 0 to 255 scale 
            workingImg(workingImg < 0) = 0; %set anything below to 0
            workingImg(workingImg > 1) = 1; %set anything above to 255 (note on a 0 to 1 scale)

            outputImg = workingImg; %we done
        end


        %function to itterate through an array and find the index of the
        %first non 0 value
        %note: we can't do binary interpolation as we may have a random
        %line with little to no background - unlikely but we're at 8bit res
        %so we should put in protection
        function dataIdx = findFirstData(~,arr, start, inc)
           
            arrLen = length(arr); %get max value before loop breaks
            currIdx = start; %get start idx 

            %loop through array by the increment trying to find one without 0s 
            while currIdx >= 1 && currIdx <= arrLen
                if arr(currIdx) ~= 0
                    dataIdx = currIdx;
                    return
                end
                currIdx = currIdx + inc;
            end
            
            dataIdx = -1; %all values are 0
        end

        %function to scan the image for black columns and rows, such that
        %they can be removed 
        function croppedStrut = cropBlackSpace(obj,img)
            %so the image matrix is a y.x.3 space, first we want to create
            %sum vectors in both the x and y directions to calculate the
            %blank rows and remove them
            xSums = sum(img,[1,3]); %Sums for each column
            ySums = sum(img,[2,3]); %Sums for each row

            %We now need to find where the black space on each side
            %Dim 1 lower, dim1 upper; dim 2 lower, dim 2 upper
            dataStart = [obj.findFirstData(ySums, 1,1),obj.findFirstData(ySums, length(ySums),-1); ...
                obj.findFirstData(xSums,1,1), obj.findFirstData(xSums, length(xSums),-1)];

            if any(dataStart == -1)
                error("Error: crop black space failed to find valid data")
            end

            newData = img(dataStart(1,1):dataStart(1,2),dataStart(2,1):dataStart(2,2),3); %pick up all the interesting data
            croppedStrut = struct("img", newData, "dataStartMat",dataStart);
        end

        function newBounds = updateBoundsFromCentre(~, centreVector, currentBounds)
            %subtract the max from the min, then
            %divide by 2 to get the radius
            imgRad = (currentBounds(:,2)-currentBounds(:,1))./2;

            %now we can subtract these from the new centre, and add to the
            %new centre to get min and max
            newLower = round(centreVector - imgRad,"TieBreaker","minusinf");
            newUpper = round(centreVector + imgRad,"TieBreaker","minusinf");
            newBounds = [newLower, newUpper];        
        end

        function expandedImg = expandImgMat(~, imgMat, expansionVec)
            imgSize = size(imgMat);
            expandedImg = imgMat;
            %check first dim (this adds downwards)
            if expansionVec(1) ~= 0
                addon = zeros([expansionVec(1),imgSize(2),3]);
                expandedImg = [imgMat; addon];
                imgSize = size(expandedImg); %refresh this cos its changed
            end

            %check second dim (this adds rightwards)
            if expansionVec(2) ~= 0
                addon = zeros([imgSize(1),expansionVec(2),3]);
                expandedImg = [imgMat, addon];
            end
        end


    end


end
