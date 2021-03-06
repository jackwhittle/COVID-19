rm(list=ls())

library(tidyverse)
library(curl)
library(readxl)
library(RcppRoll)
library(geojsonio)
library(broom)
library(zoo)
library(gganimate)

#Get English UTLA-level case trajectories
temp <- tempfile()
source <- "https://coronavirus.data.gov.uk/downloads/csv/coronavirus-cases_latest.csv"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
data <- read.csv(temp)[,c(1,2,3,4,5,8)]
colnames(data) <- c("name", "code", "type", "date", "cases", "cumul_cases")
data$date <- as.Date(data$date)
data <- subset(data, type=="Upper tier local authority")

#Set up skeleton dataframe with dates
LAcodes <- unique(data$code)
min <- min(data$date)
max <- max(data$date)

skeleton <- data.frame(code=rep(LAcodes, each=(max-min+1), times=1), date=rep(seq.Date(from=min, to=max, by="day"), each=1, times=length(LAcodes)))

#Map data onto skeleton
fulldata <- merge(skeleton, data[,-c(1,3)], by=c("code", "date"), all.x=TRUE, all.y=TRUE)

#Bring in LA names
temp <- data %>%
  group_by(code) %>%
  slice(1L)
fulldata <- merge(fulldata, temp[,c(1,2)], by="code")

#Fill in blank days
fulldata$cases <- ifelse(is.na(fulldata$cases), 0, fulldata$cases)

#Calculate cumulative sums so far
fulldata <- fulldata %>%
  arrange(code, date) %>%
  group_by(code) %>%
  mutate(cumul_cases=cumsum(cases))

fulldata$country <- "England"

#Get Welsh data
#Read in data
temp <- tempfile()
source <- "http://www2.nphs.wales.nhs.uk:8080/CommunitySurveillanceDocs.nsf/b4472ecab22fa0d580256f10003199e7/49b553ea08eff65780258566004e8895/$FILE/Rapid%20COVID-19%20surveillance%20data.xlsx"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
data.w <- read_excel(temp, sheet=2)[,c(1:4)]

colnames(data.w) <- c("name", "date", "cases", "cumul_cases")
data.w$date <- as.Date(data.w$date)

#Read in UTLA/LA lookup
temp <- tempfile()
source <- "https://opendata.arcgis.com/datasets/3e4f4af826d343349c13fb7f0aa2a307_0.csv"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
lookup <- read.csv(temp)
colnames(lookup) <- c("no", "LTcode", "LTname", "code", "name")

#Sort out Isles of Scilly
lookup$code <- ifelse(lookup$LTcode=="E06000053", "E06000052", as.character(lookup$code))

#Lookup codes for Welsh LAs
data.w <- merge(data.w, subset(lookup, substr(code,1,1)=="W"), all.x=TRUE, by="name")[,c(1:4,8)]
data.w <- data.w[,c(5,2,3,4,1)]

data.w$country <- "Wales"

#Merge with English data
fulldata <- bind_rows(fulldata, subset(data.w, !is.na(code)))

#Merge in LTLAs - cloning UTLA data
fulldata <- merge(lookup[,-c(1,5)], fulldata, by="code", all.x=T, all.y=T)

#Get Scottish data
temp <- tempfile()
source <- "https://raw.githubusercontent.com/DataScienceScotland/COVID-19-Management-Information/master/COVID19%20-%20Daily%20Management%20Information%20-%20Scottish%20Health%20Boards%20-%20Cumulative%20cases.csv"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
data.s <- read.csv(temp)

data.s$Date <- as.Date(data.s$Date)

data_long.s <- gather(data.s, HB, cumul_cases, c(2:15))

#Treat supressed numbers as 0
data_long.s$cumul_cases <- as.numeric(ifelse(data_long.s$cumul_cases=="*", 0, data_long.s$cumul_cases))

#Calculate daily cases
data_long.s <- data_long.s %>%
  arrange(HB, Date) %>%
  group_by(HB) %>%
  mutate(cases=cumul_cases-lag(cumul_cases,1))

data_long.s$cases <- ifelse(is.na(data_long.s$cases), 0, data_long.s$cases)

#Bring in HB codes
data_long.s$code <- case_when(
  data_long.s$HB=="Ayrshire.and.Arran" ~ "S08000015",
  data_long.s$HB=="Borders" ~ "S08000016",
  data_long.s$HB=="Dumfries.and.Galloway" ~ "S08000017",
  data_long.s$HB=="Fife" ~ "S08000029",
  data_long.s$HB=="Forth.Valley" ~ "S08000019",
  data_long.s$HB=="Grampian" ~ "S08000020",
  data_long.s$HB=="Greater.Glasgow.and.Clyde" ~ "S08000031",
  data_long.s$HB=="Highland" ~ "S08000022",
  data_long.s$HB=="Lanarkshire" ~ "S08000032",
  data_long.s$HB=="Lothian" ~ "S08000024",
  data_long.s$HB=="Orkney" ~ "S08000025",
  data_long.s$HB=="Shetland" ~ "S08000026",
  data_long.s$HB=="Tayside" ~ "S08000030",
  data_long.s$HB=="Western.Isles" ~ "S08000028")

#Get Health board to LA lookup
temp <- tempfile()
source <- "http://statistics.gov.scot/downloads/file?id=5a9bf61e-7571-45e8-a307-7c1218d5f6b5%2FDatazone2011Lookup.csv"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
lookup.s <- read.csv(temp)
lookup.s <- distinct(lookup.s, Council, .keep_all=TRUE)[,c(6,7)]
colnames(lookup.s) <- c("LTcode", "code")

#Merge in Health Boards to Councils, cloning data within HBs
data_long.s <- merge(lookup.s, data_long.s, by="code")
colnames(data_long.s) <- c("code", "LTcode", "date", "name", "cumul_cases", "cases")
data_long.s <- data_long.s[,c(1,2,3,6,5,4)]

data_long.s$country <- "Scotland"

#Merge into E&W data
fulldata <- bind_rows(fulldata, data_long.s)

#Grab NI data from Tom White's excellent resource
temp <- tempfile()
source <- "https://raw.githubusercontent.com/tomwhite/covid-19-uk-data/master/data/covid-19-cases-uk.csv"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
data.ni <- subset(read.csv(temp), Country=="Northern Ireland")[,-c(2)]
colnames(data.ni) <- c("date", "code", "name", "cumul_cases")
data.ni$date <- as.Date(as.character(data.ni$date))

#Remove missing location rows
data.ni$code <- as.character(data.ni$code)
data.ni <- subset(data.ni, code!="")

#Set up skeleton dataframe for missing dates
NILAs <- unique(data.ni$code)
min <- min(data.ni$date)
max <- max(data.ni$date)

skeleton <- data.frame(code=rep(NILAs, each=(max-min+1)), 
                       date=rep(seq.Date(from=min, to=max, by="day"), each=1, times=length(NILAs)))

#Map data onto skeleton
fulldata.ni <- merge(skeleton, data.ni[,-c(3)], by=c("code", "date"), all.x=TRUE, all.y=TRUE)

#Interpolate missing dates
fulldata.ni <- fulldata.ni %>%
  arrange(code, date) %>%
  group_by(code) %>%
  mutate(cumul_cases=na.approx(cumul_cases), cases=cumul_cases-lag(cumul_cases,1))

fulldata.ni$cases <- ifelse(is.na(fulldata.ni$cases), 0, fulldata.ni$cases)
fulldata.ni$cases <- ifelse(fulldata.ni$cases<0, 0, fulldata.ni$cases)

#bring back names
fulldata.ni <- merge(fulldata.ni, data.ni[,c(2,3)], by="code")

fulldata.ni$country <- "Northern Ireland"

#Merge into E, W & S data
fulldata <- bind_rows(fulldata, fulldata.ni)

#Read in data by Irish counties
temp <- tempfile()
source <- "http://opendata-geohive.hub.arcgis.com/datasets/d9be85b30d7748b5b7c09450b8aede63_0.csv?outSR={%22latestWkid%22:3857,%22wkid%22:102100}"
temp <- curl_download(url=source, destfile=temp, quiet=FALSE, mode="wb")
data.i <- read_csv(temp)

#Strip out geographical data
data.i <- data.i[,c(1,4,11)]
colnames(data.i) <- c("TimeStamp", "name", "cumul_cases")

#Convert timestamp to date
data.i$date <- as.Date(substr(data.i$TimeStamp, 1, 10))
data.i <- data.i[,-c(1)]

#Calculate daily cases
data.i <- data.i %>%
  arrange(name, date) %>%
  group_by(name) %>%
  mutate(cases=cumul_cases-lag(cumul_cases,1))

#For 3 counties (Leitrim, Limerick and Sligo) the case count goes *down* in early May. Ignore these for now
data.i$cases <- ifelse(is.na(data.i$cases), 0, data.i$cases)
data.i$cases <- ifelse(data.i$cases<0, 0, data.i$cases)

data.i$country <- "Republic of Ireland"

#Allocate (made up) codes to match into hex map
data.i$code <- case_when(
  data.i$name=="Donegal" ~ "I00000001",
  data.i$name=="Sligo" ~ "I00000002",
  data.i$name=="Mayo" ~ "I00000003",
  data.i$name=="Leitrim" ~ "I00000004",
  data.i$name=="Monaghan" ~ "I00000005",
  data.i$name=="Galway" ~ "I00000006",
  data.i$name=="Roscommon" ~ "I00000007",
  data.i$name=="Cavan" ~ "I00000008",
  data.i$name=="Meath" ~ "I00000009",
  data.i$name=="Louth" ~ "I00000010",
  data.i$name=="Clare" ~ "I00000011",
  data.i$name=="Longford" ~ "I00000012",
  data.i$name=="Westmeath" ~ "I00000013",
  data.i$name=="Kildare" ~ "I00000014",
  data.i$name=="Dublin" ~ "I00000015",
  data.i$name=="Limerick" ~ "I00000016",
  data.i$name=="Offaly" ~ "I00000017",
  data.i$name=="Laois" ~ "I00000018",
  data.i$name=="Wicklow" ~ "I00000019",
  data.i$name=="Kerry" ~ "I00000020",
  data.i$name=="Tipperary" ~ "I00000021",
  data.i$name=="Kilkenny" ~ "I00000022",
  data.i$name=="Carlow" ~ "I00000023",
  data.i$name=="Wexford" ~ "I00000024",
  data.i$name=="Cork" ~ "I00000025",
  data.i$name=="Waterford" ~ "I00000026")

#Merge into UK data
fulldata <- bind_rows(fulldata, data.i)

#tidy up
fulldata$LTcode <- ifelse(is.na(fulldata$LTcode), fulldata$code, fulldata$LTcode)
fulldata$LTname <- ifelse(is.na(fulldata$LTname), fulldata$name, fulldata$LTname)

#Calculate rolling averages of case numbers
fulldata <- fulldata %>%
  arrange(LTcode, date) %>%
  group_by(LTcode) %>%
  mutate(casesroll_avg=roll_mean(cases, 5, align="right", fill=0))

#Get number of LTLAs for each UTLA
fulldata <-  fulldata %>%
  group_by(code, date) %>%
  mutate(LAcount=length(unique(LTcode)))

#Divide cases equally between LTLAs for composite UTLAs
fulldata$casesroll_avg <- fulldata$casesroll_avg/fulldata$LAcount

#Bring in hexmap
#Read in hex boundaries (adapted from from https://olihawkins.com/2018/02/1 and ODI Leeds)
hex <- geojson_read("Data/UKIRELA.geojson", what="sp")

# Fortify into a data frame format to be shown with ggplot2
hexes <- tidy(hex, region="id")

data <- left_join(hexes, fulldata, by=c("id"="LTcode"), all.y=TRUE)
data$date <- as.Date(data$date)

#extract latest date with full UK data
data <- data %>%
  group_by(country) %>%
  mutate(min=min(date), max=max(date))

completefrom <- max(data$min)
completeto <- min(data$max)

HexAnim <- ggplot()+
  geom_polygon(data=subset(data, date>as.Date("2020-03-06") & date<=completeto), 
               aes(x=long, y=lat, group=id, fill=casesroll_avg))+
  coord_fixed()+
  scale_fill_distiller(palette="Spectral", name="Daily confirmed\ncases (5-day\nrolling avg.)")+
  theme_classic()+
  theme(axis.line=element_blank(), axis.ticks=element_blank(), axis.text=element_blank(),
        axis.title=element_blank(),  plot.title=element_text(face="bold"))+
  transition_time(date)+
  labs(title="Visualising the spread of COVID-19 across the UK & Ireland",
       subtitle="Rolling 5-day average number of new confirmed cases.\nDate: {frame_time}",
       caption="Data from PHE, PHW, ScotGov, DoHNI/Tom White & Gov.ie\nVisualisation by @VictimOfMaths")

animate(HexAnim, duration=18, fps=10, width=2000, height=3000, res=300, renderer=gifski_renderer("Outputs/HexAnim.gif"), 
        end_pause=60)

HexAnimUK <- ggplot()+
  geom_polygon(data=subset(data, date>as.Date("2020-03-06") & date<=as.Date("2020-05-12") & country!="Republic of Ireland"), 
               aes(x=long, y=lat, group=id, fill=casesroll_avg))+
  coord_fixed()+
  scale_fill_distiller(palette="Spectral", name="Daily confirmed\ncases (5-day\nrolling avg.)", na.value="white")+
  theme_classic()+
  theme(axis.line=element_blank(), axis.ticks=element_blank(), axis.text=element_blank(),
        axis.title=element_blank(),  plot.title=element_text(face="bold"))+
  transition_time(date)+
  labs(title="Visualising the spread of COVID-19 across the UK & Ireland",
       subtitle="Rolling 5-day average number of new confirmed cases.\nDate: {frame_time}",
       caption="Data from PHE, PHW, ScotGov & DoHNI/Tom White\nVisualisation by @VictimOfMaths")

animate(HexAnimUK, duration=18, fps=10, width=2000, height=3000, res=300, renderer=gifski_renderer("Outputs/HexAnimUK.gif"), 
        end_pause=60)
