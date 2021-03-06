#' Estimate uncertainty of spatial prediction models
#'
#' @description
#' this function estimates uncertainty of spatial prediction models by
#' considering the distance of new data (i.e. a Raster Stack of spatial predictors
#' used in the models) in the predictor variable space to the data used for model
#' training. Predictors can be weighted in the ideal case based on the internal
#' variable importance of the machine learning algorithm used for model training.
#'
#' @param train a data.frame containing the data used for model training
#' @param predictors A RasterStack, RasterBrick or data.frame containing the data
#' the model was meant to make predictions for.
#' @param weight A data.frame containing weights for each variable
#' @param model A caret model used to extract weights from (based on variable importance)
#' @param variables character vector of predictor variables. if "all" then all variables
#' of the train dataset are used. Check varImp(model).
#' @param scale logical. If TRUE uncertainty is scaled between 0 and 1. See Details.
#' @param cl Cluster object created with parallel::makeCluster. To run things in parallel.
#' @param range numeric. Only specify if the range should not be detected automatically
#' @details Interpretation of results: If a location is very similar to the properties
#' of the training data it will have a low distance in the predictor variable space
#' (low uncertainty) while locations that are very different in its properties
#' will have a high uncertainty.
#' If scale is FALSE then uncertainty is returned as distance scaled by the length of the gradent in the training data:
#' The further the distance in this variable space, the larger the uncertainty gets. e.g. an uncertainty of 0.5 means
#' that the distance to the nearest training point is half the distance of the gradient observed in the training data.
#' The uncertainty can get higher than 1 if the nearest training point is further away than the length of the gradient in the training data.
#' This happens when we apply a model to an area that is fully out of the range of what the model was trained on.
#' If scale is TRUE then the output is scaled between 0 and 1, but no comparison between models will be possible.
#'
#' @return A RasterLayer or data.frame
#' @author
#' Hanna Meyer
#'
#' @examples
#' \dontrun{
#' library(sf)
#' library(raster)
#' library(caret)
#'
#' # prepare sample data:
#' dat <- get(load(system.file("extdata","Cookfarm.RData",package="CAST")))
#' dat <- aggregate(dat[,c("VW","Easting","Northing")],by=list(as.character(dat$SOURCEID)),mean)
#' pts <- st_as_sf(dat,coords=c("Easting","Northing"))
#' pts$ID <- 1:nrow(pts)
#' studyArea <- stack(system.file("extdata","predictors_2012-03-25.grd",package="CAST"))[[1:8]]
#' trainDat <- extract(studyArea,pts,df=TRUE)
#' trainDat <- merge(trainDat,pts,by.x="ID",by.y="ID")
#'
#' # visualize data spatially:
#' spplot(scale(studyArea))
#' plot(studyArea$DEM)
#' plot(pts[,1],add=TRUE,col="black")
#'
#' # first calculate uncertainty based on a set of variables with equal weights:
#' variables <- c("DEM","Easting","Northing")
#' plot(uncertainty(trainDat,studyArea,variables=variables))
#' plot(pts[,1],add=TRUE,col="black") #add training data to plot
#'
#' # or weight variables based on variable improtance from a (simple) trained model:
#' set.seed(100)
#' model <- train(trainDat[,which(names(trainDat)%in%variables)],
#' trainDat$VW,method="rf",importance=TRUE,tuneLength=1)
#' prediction <- predict(studyArea,model)
#' plot(varImp(model,scale=FALSE))
#' # note that coordinates are the major predictors here,
#' # so uncertainty becomes higher when moving away from the training data:
#' par(mfrow=c(1,2))
#' plot(prediction,main="predicted VW")
#' plot(uncertainty(trainDat,studyArea,model=model,variables=variables),
#' main="scaled uncertainty")
#' plot(pts["Group.1"],add=TRUE,col="black") #add training data to plot
#' }
#' @export uncertainty
#' @aliases uncertainty

uncertainty <- function (train, predictors, weight=NA, model=NA,
                         variables="all",scale=FALSE, cl=NULL, range=NULL){
  ### if not specified take all variables from train dataset as default:
  if(nrow(train)<=1){stop("at least two training points need to be specified")}
  if(length(variables)==1&&variables=="all"){
    variables=names(train)
  }
  #### Prepare output as either as RasterLayer or vector:
  out <- NA
  if (class(predictors)=="RasterStack"|class(predictors)=="RasterBrick"|
      class(predictors)=="RasterLayer"){
    out <- predictors[[1]]
    names(out) <- "uncertainty"
  }
  #### Extract weights from trained model:
  weight <- tryCatch(if(model$modelType=="Classification"){
    as.data.frame(t(apply(caret::varImp(model,scale=F)$importance,1,mean)))
  }else{
    as.data.frame(t(caret::varImp(model,scale=F)$importance[,"Overall"]))
  }, error=function(e) e)
  if(!inherits(weight, "error")){
    #weight <- t(apply(weight,1,scales::rescale,to = c(1, 100)))
    names(weight)<- rownames(caret::varImp(model,scale=F)$importance)
  }else{
    message("note: variables were not weighted either because no weights or model were given,
    or no variable importance could be retrieved from the given model.
    Check caret::varImp(model)")
  }
  #### order data:
  if (class(predictors)=="RasterStack"|class(predictors)=="RasterBrick"|
      class(predictors)=="RasterLayer"){
    predictors <- predictors[[na.omit(match(variables, names(predictors)))]]
  }else{
    predictors <- predictors[,na.omit(match(variables, names(predictors)))]
  }
  train <- train[,na.omit(match(variables, names(train)))]
  if(!inherits(weight, "error")){
    weight <- weight[,na.omit(match(variables, names(weight)))]
    if (any(weight<0)){
      weight[weight<0]<-0
      message("negative weights were set to 0")
    }
  }
  #### Scale data and weight predictors if applicable:
  train <- scale(train,center=FALSE)
  scaleparam <- attributes(train)
  if(!inherits(weight, "error")){
    train <- sapply(1:ncol(train),function(x){train[,x]*unlist(weight[x])})
  }
  if (class(predictors)=="RasterStack"|class(predictors)=="RasterBrick"|
      class(predictors)=="RasterLayer"){
    predictors <- raster::as.data.frame(predictors)
  }
  predictors <- scale(predictors,center=FALSE,#scaleparam$`scaled:center`
                      scale=scaleparam$`scaled:scale`)

  if(!inherits(weight, "error")){
    predictors <- sapply(1:ncol(predictors),function(x){predictors[,x]*unlist(weight[x])})
  }

  # calculate maximum potential distance:
  minvalues <- apply(train,2,function(x){min(x,na.rm=TRUE)}) # für jedes Raster min
  maxvalues <- apply(train,2,function(x){max(x,na.rm=TRUE)}) # für jedes Raster max

  maxdist <- dist(rbind(maxvalues,minvalues))
  #### For each pixel caclculate distance to each training point and search for
  #### min distance:
  if(!is.null(cl)){ # if parallel then use parapply:
    parallel::clusterExport(cl=cl, varlist=c("train"))
    mindist <- parallel::parApply(cl=cl,predictors,1,FUN=function(x){
      tmp <- NA
      for (i in 1:nrow(train)){
        current_min <- dist(rbind(x,train[i,]))
        current_min <- pmin(current_min,tmp,na.rm=T)
        tmp <- current_min
      }
      return(current_min)
    })
  }else{ # ...if not in parallel loop over train data:
    tmp <- NA
    for (i in 1:nrow(train)){
      mindist <- apply(predictors,1,function(x){dist(rbind(x,train[i,]))})
      mindist <- pmin(mindist,tmp,na.rm=T)
      tmp <- mindist
    }
  }

  #scale the distance to nearest training point by the maximum possible distance
  if(is.null(range)){
  mindist <- mindist/maxdist
  }else{
    mindist <- mindist/unlist(range)
  }
  #### return (scaled) distances as RasterLayer or vector:
  if (class(out)=="RasterLayer"){
    if(scale){
      raster::values(out) <- scales::rescale(mindist, to = c(0, 1))
    }else{
      raster::values(out) <- mindist
    }
  } else{
    if(scale){
      out <- scales::rescale(mindist, to = c(0, 1))
    }else{
      out <- mindist
    }
  }
  attributes(out)$range <- maxdist
  return(out)
}
