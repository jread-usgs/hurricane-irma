# Find sites that are of interest to get data for.
process.storm_sites <- function(viz = as.viz('storm-sites')){
  library(magrittr)
  
  checkRequired(viz, c("perc_flood_stage", "begin_date_filter"))
  depends <- readDepends(viz)
  checkRequired(depends, c("view-limits", "sites", "storm-area-filter", 
                           "nws-data"))
  
  view.lims <- depends[["view-limits"]]
  sites <- depends[['sites']] 
  storm_poly <- depends[['storm-area-filter']]
  nws.sites <- depends[['nws-data']]$sites
  nws.data <- depends[['nws-data']]$forecasts
  
  library(dplyr)
  sites$dv_begin_date <- as.Date(sites$dv_begin_date)
  
  sites.sp <- sp::SpatialPointsDataFrame(cbind(sites$dec_long_va,
                                               sites$dec_lat_va), 
                                         data = sites,
                                         proj4string = sp::CRS("+proj=longlat +ellps=GRS80 +no_defs"))
  
  sites.sp <- sp::spTransform(sites.sp, sp::CRS(view.lims$proj.string))
  
  storm_poly <- sp::spTransform(storm_poly, sp::CRS(view.lims$proj.string))
  
  percent_flood_stage <- as.numeric(viz[["perc_flood_stage"]])
  begin_date_filter <- as.Date(viz[["begin_date_filter"]])
  
  #this will be modified in a later process step, based on NWIS observations
  #need this filtering first to limit the amount of data pulled from NWIS
  is.featured <- rgeos::gContains(storm_poly, sites.sp, byid = TRUE) %>% 
    rowSums() %>% 
    as.logical() & 
    sites$site_no %in% nws.sites$site_no[!is.na(nws.sites$flood.stage)] & # has an NWS flood stage
    sites$dv_begin_date < begin_date_filter & # has period of record longer than some begin date
    !(sites$site_no %in% c('02223000', '02207220', '02246000', '02467000')) # is not one of our manually selected bad sites
  
  #might be nice to have this in it's own step 
  sites.sp@data <- data.frame(id = paste0('nwis-', sites.sp@data$site_no), 
                         class = ifelse(is.featured, 'nwis-dot','inactive-dot'),
                         r = ifelse(is.featured, '3.5','1'),
                         onmousemove = ifelse(is.featured, sprintf("hovertext('USGS %s',evt);",sites.sp@data$site_no), ""),
                         onmouseout = ifelse(is.featured, sprintf("setNormal('sparkline-%s');setNormal('nwis-%s');hovertext(' ');", sites.sp@data$site_no, sites.sp@data$site_no), ""),
                         onmouseover= ifelse(is.featured, sprintf("setBold('sparkline-%s');setBold('nwis-%s');", sites.sp@data$site_no, sites.sp@data$site_no), ""),
                         onclick=ifelse(is.featured, sprintf("openNWIS('%s', evt);", sites.sp@data$site_no), ""), 
                         stringsAsFactors = FALSE)
  
  saveRDS(sites.sp, viz[['location']])
}

#has a site passed flood stage or forecasted to?
process.select_flood_sites <- function(viz = as.viz('storm-sites-flood')) {
  library(dplyr)
  depends <- readDepends(viz)
  
  gage_data <- depends[['gage-data']]
  storm_sites <- depends[['storm-sites']] #this needs to be filtered and resaved
  storm_sites_ids <- gsub(pattern = "nwis-", replacement = "", 
                          x = storm_sites$id)
  
  nws_list <- depends[['nws-data']]
  nws_forecast <- nws_list[['forecasts']] %>% rename(NWS=site)
  nws_sites <- nws_list[['sites']]
  nws_joined <- left_join(nws_forecast, nws_sites, by = "NWS")
  
  #filter nws and gage data down to storm sites
  nws_joined <- filter(nws_joined, site_no %in% storm_sites_ids) %>% 
    mutate(forecast_vals = as.numeric(forecast_vals))
  gage_data <- filter(gage_data, site_no %in% storm_sites_ids)
  
  gage_data_max <- gage_data %>% group_by(site_no) %>% summarize(max_gage = max(p_Inst))
  nws_max <- nws_joined %>% group_by(site_no, flood.stage) %>% 
    summarize(max_forecast = max(forecast_vals))
  
  gage_nws_join <- left_join(gage_data_max, nws_max, by = "site_no") %>% 
    filter(!is.na(flood.stage))
  
  #has it passed flood stage, or forecasted to?
  gage_nws_flood <- gage_nws_join %>% filter(max_gage > flood.stage | max_forecast > flood.stage) %>% 
    mutate(site_no = paste("nwis", site_no, sep = "-"))
  
  #filter storm sites
  storm_sites_filtered <- storm_sites[storm_sites$id %in% gage_nws_flood$site_no,]
  saveRDS(object = storm_sites_filtered, file = viz[['location']])
}

#fetch NWIS iv data, downsample to hourly

process.getNWISdata <- function(viz = as.viz('gage-data')){
  required <- c("depends", "location")
  checkRequired(viz, required)
  depends <- readDepends(viz)
  siteInfo <- depends[['storm-sites']]
  sites_active <- dplyr::filter(siteInfo@data, class == 'nwis-dot')$id
  sites_active <- gsub(pattern = "nwis-", replacement = "", x = sites_active)
  
  dateTimes <- depends[['timesteps']]$times
  dateTimes_fromJSON <- as.POSIXct(strptime(dateTimes, format = '%b %d %I:%M %p'), 
                                   tz = "America/New_York")
  
  start.date <-  as.Date(dateTimes_fromJSON[1])
  end.date <- as.Date(dateTimes_fromJSON[length(dateTimes)])
  
  sites_fetcher_params <- getContentInfo('sites')
  parameter_code <- sites_fetcher_params[['pCode']]
  
  nwisData <- dataRetrieval::renameNWISColumns(
    dataRetrieval::readNWISdata(service="iv",
                                parameterCd=parameter_code,
                                sites = sites_active,
                                startDate = start.date,
                                endDate = end.date,
                                tz = "America/New_York"))
  
  nwisData <- dplyr::filter(nwisData, dateTime %in% dateTimes_fromJSON)
  
  names(nwisData)[which(grepl(".*_Inst$", names(nwisData)))] <- "p_Inst"
  names(nwisData)[which(grepl(".*_Inst_cd$", names(nwisData)))] <- "p_Inst_cd"
  
  location <- viz[['location']]
  saveRDS(nwisData, file=location)
}


#' 
#' filter sites to just those that have exceed flood stage
#' for the time stamp selected
process.flood_sites_classify <- function(viz = as.viz("flood-sites-classify")){
  library(dplyr)
  
  depends <- readDepends(viz)
  nws_data <- depends[["nws-data"]]$sites
  gage_data <- depends[["timestep-discharge"]]
  storm_sites <- depends[["storm-sites-flood"]]
  
  site.nos <- sapply(names(gage_data), function(x) strsplit(x, '[-]')[[1]][2], USE.NAMES = FALSE)
  
  #this won't work if we switched to discharge
  pcode <- getContentInfo('sites')$pCode
  stopifnot(pcode == "00065")
  
  class_df <- data.frame(stringsAsFactors = FALSE)
  #actually create the classes
  for(site in site.nos) {
    flood.stage <- filter(nws_data, site_no == site) %>% .$flood.stage %>% .[1]
    which.floods <- which(gage_data[[paste0('nwis-',site)]]$y > flood.stage)
    site_class <- paste(paste("f", which.floods, sep = "-"), collapse = " ")
    class_df_row <- data.frame(site_no = site, class = site_class, 
                               stringsAsFactors = FALSE)
    class_df <- bind_rows(class_df, class_df_row)
  }
  d.out <- mutate(class_df, id = paste0('nwis-', site_no)) %>% 
    select(id, raw.class = class) %>% left_join(storm_sites@data, .) %>% 
    mutate(raw.class = ifelse(is.na(raw.class), "", paste0(" ", raw.class))) %>% 
    mutate(class = paste0(class,  raw.class)) %>% select(-raw.class)
  storm_sites@data <- d.out
  saveRDS(storm_sites, viz[['location']])
}
