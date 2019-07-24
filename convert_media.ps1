###############################################################################
# convert_media.ps1                                                           #
#                                                                             #
# Copyright 2019 - K. Austin Newman                                           #
# Convert media using Don Melton's Video Transcoding Project                  #
#                                                                             #
###############################################################################

# -----------------------------------------------------------------
#  Variables go here
# -----------------------------------------------------------------

$intVersion="0.25.04"

$drvData = get-volume -FileSystemLabel "Data"
$drvArchive = get-volume -FileSystemLabel "MediaArchive"
$strRootVol = $drvData.DriveLetter
$strArchiveVol = $drvArchive.DriveLetter

# That should be all the variables that are required

$dirWorkVolume = "$strRootVol`:\Workflows"
$dirProcessing = "$dirWorkVolume\Encoding\Processing"
$dirArchive = "$dirWorkVolume\Outbox\Archive"
$strTVRegEx = "([sS]([0-9]{2,}|[X]{2,})[eE]([0-9]{2,}|[Y]{2,}))"
$dirEncodingLogs = "$strArchiveVol`:\Encoding Logs"

# -----------------------------------------------------------------
#  Begin Script
# -----------------------------------------------------------------

# Verify that environment is correct, and all directories
if ( -not (Test-Path "$dirWorkVolume")){
	Write-warning -Message "$dirWorkVolume is not present. Aborting."
}

# Make sure that we have met all the requirements
$aTools = "ffprobe","transcode-video"
foreach ($tool in $aTools){
	if ( $null -eq (Get-Command "$tool" -ErrorAction SilentlyContinue)){
   	Write-warning -Message "Executable not in path: $tool"
   	$strExit = "True"
   	}
}
if ($strExit -eq "True"){
	Write-warning "Exiting due to previous errors"
 	exit 1
}

# Take all command line arguments and pass through to test options, unless the option is prep or prepenv

$strTestOpts = $args

if  ( $strTestOpts -eq "prepenv" ){
	$aPaths = "Outbox/Archive","Outbox/Exceptions","Outbox/Movies","Outbox/TV","Encoding/Queue","Encoding/Intake","Encoding/Ready","Encoding/Processing","Encoding/Staging/720p","Encoding/Staging/4k","Encoding/Staging/Default","Encoding/Staging/x265"
	foreach ($dir in $aPaths){
			$strTestDir = "$dirWorkVolume/$dir"
			If(!(Test-Path $strTestDir)){
				New-Item -ItemType Directory -Force -Path $strTestDir
			}
	}
	Write-Output "Environment is correct - exiting."
	Exit 0
}

# Create array of all MKV files found in the workflow
$fPrepArray = Get-ChildItem -recurse $dirWorkVolume\Encoding\Intake -include *.mkv -File

# Start working through the file prep and analysis
foreach ($element in $fPrepArray){
	Write-Output "Prepping $element"
	$strTheFile = $element.ToString()
	# Flag any track labeled "forced"
	$strResult = ffprobe -i "$strTheFile" -select_streams s -show_streams -of json -v quiet | jq -r '.streams[] | .tags | .title'
	$intSubCount = 0
	ForEach ($subtrack in $strResult){
		$intSubCount++
		If ( $subtrack -match "[Ff][Oo][Rr][Cc][Ee][Dd]" ){
			Write-Output "Setting forced subtitle track on "$strTheFile" - Subtitle track = "$intSubCount""
			mkvpropedit --edit track:s"$intSubCount" --set flag-forced=1 "$strTheFile"
		}
	}
	# Move file to default processing
	If ($strTheFile -match $strTVRegEx){
		filebot -rename "$strTheFile" --db TheTVDB --format "$dirWorkVolume\Encoding\Staging\Default\{n} - {s00e00} - {t}" -non-strict  > $null
	}
	else {
	filebot -rename "$strTheFile" --db TheMovieDB --format "$dirWorkVolume\Encoding\Staging\Default\{n.colon(' - ')} ({y})" -non-strict > $null
	}
}

# Exit here if only prepping
if  ( $strTestOpts -eq "prep" ){
	Write-output "All files prepped. Exiting."
	exit 0
}

$strGeneralOpts = "--crop detect --fallback-crop ffmpeg"

$fArray = Get-ChildItem -recurse $dirWorkVolume\Encoding\Staging -include *.mkv -File | Where-Object {$_.PSParentPath -notlike "*Ready*"}
foreach ($element in $fArray){
	Write-Output "Processing $element"
	$strTheFile = $element.ToString()
	$strFilename = (Get-Item $strTheFile).Basename
	$strExtension = (Get-Item $strTheFile).Extension
	$strFileProfile = $strTheFile.split('\')[4]

	# Get media info
	$strMI = ffprobe -i "$strTheFile" -show_format -show_streams -show_data -v quiet -print_format json=compact=1 -v quiet
	$strMIName = "$strMI" | jq '.format|.tags|.title'
	$strMIName = ( $strMIName -replace '"', "" )
	$intHeight = "$strMI" | jq '.streams[0]|.height'
	$intHeight = [int]$intHeight
	if ( $intHeight -le 480 ) {
		$strHeight = "DVD"
		$strFileProfile = "DVD"
	}
 	elseif ( $intHeight -gt 480 -And $intHeight -le 720 ) {
 		$strHeight = "720p"
 	}
	elseif ( $intHeight -gt 720 -And $intHeight -le 1080 ) {
 		$strHeight = "1080p"
 	}
	elseif ( $intHeight -gt 1080 ) {
 		$strHeight = "2160p"
 	}

	# Compare file name and movie name. If different, write new movie name.
	if ( -not ( "$strFilename" -eq "$strMIName" )){
		Write-Output "Changing metadata title to match movie name"
		mkvpropedit "$strTheFile" --edit info --set "title=$strFilename"
	}

	# Find out what kind of transcode we're dealing with.
	# Raw - No encoding, renames original to spec, copies to archive and outbox
	# 720p constrains height to 720 pixels, encodes file with x264, renames original, copies to archive and outbox
	# x265 will use 10-bit x265 encoder, encodes file, renames original, copies to archive and outbox
	# 4k encodes file w x264, renames original, copies to archive and outbox
	# Default constrains height to 1080p, encodes file with x264, renames original, copies to archive and outbox
	
	if ( "$strFileProfile" -eq "720p" ) {
 		$strDestLabel = "BluRay-720p"
 		$strVideoOpts = "--720p --avbr --quick"
	}
	elseif ( "$strFileProfile" -eq "x265" ) {
 		$strDestLabel = "H265 BluRay-$strHeight"
 		$strVideoOpts = "--abr --handbrake-option encoder=x265_10bit"
	}
	elseif ( "$strFileProfile" -eq "4k" ) {
 		$strDestLabel = "BluRay-$strHeight"
 		$strVideoOpts = "--avbr --quick"
	}
 	elseif ( "$strFileProfile" -eq "DVD" ) {
 		$strDestLabel = "DVD"
 		$strVideoOpts = "--avbr --quick --target 480p=2000"
	}
	else {
 		$strDestLabel = "BluRay-1080p"
 		$strVideoOpts = "--max-height 1080 --avbr --quick"
	}

	$strDestFileName = "$strFilename $strDestLabel$strExtension"
	$strArchFileName = "$strFilename Remux-$strHeight$strExtension"
	#$strDestOpts = "$dirProcessing\$strDestFileName"

	# Set Subtitle Options - Soft add all eng subtitles, find forced and mark in file
	
	$strSubInfo = ffprobe -i "$strTheFile" -select_streams s -show_streams -print_format json=compact=1 -v quiet
	$intSubCount = 0
	$strSubOpts = "--no-auto-burn"
	$subtrack = "$strSubInfo" | jq -r '.streams[] | .disposition | .forced'
	ForEach ( $element in $subtrack ){
		$strLanguage = "$strSubInfo" | jq -r ".streams[$intSubCount] | .tags | .language"
		$intSubCount++
		if ( "$element" -eq "1" -And "$strLanguage" -eq "eng" ){
			$strSubOpts = "$strSubOpts --add-subtitle $intSubCount --force-subtitle $intSubCount"
		}
		elseif ( "$strLanguage" -eq "eng" ){
			$strSubOpts = "$strSubOpts --add-subtitle $intSubCount"
		}
	}

	# Set Audio Options
	$intAudCount = 0
	$strAudioInfo = ffprobe -i "$strTheFile" -select_streams a -show_streams -print_format json=compact=1 -v quiet
	ForEach ( $audtrack in ( "$strAudioInfo" | jq -r '.streams[] | .tags | .title' )){
		$strLanguage = "$strAudioInfo" | jq -r ".streams[$intAudCount] | .tags | .language"
		$intAudCount++
		if ( "$strLanguage" -eq "eng" -And "$audtrack" -match "[Cc][Oo][Mm][Mm][Ee][Nn][Tt][Aa][Rr][Yy]" ){
			$strAudioOptions = "$strAudioOptions --add-audio $intAudCount=""$audtrack"""
		}
		elseif ( "$strLanguage" -eq "eng" ){
			$strAudioOptions = "$strAudioOptions --add-audio $intAudCount"
		}
	}

	$strAudioOptions = "$strAudioOptions --audio-width 1=surround --ac3-encoder eac3 --ac3-bitrate 640 --keep-ac3-stereo"

	# Here we go. Time to start the process.
	$outfile = "$dirWorkVolume\Encoding\Queue\$strMIName.cmd"
	If (Test-Path $outfile){
		Remove-Item $outfile
	}
	Move-Item "$strTheFile" "$dirProcessing"
	$strSourceFile = "$dirProcessing\$strFilename$strExtension"
	if ( "$strDestFileName" -match "$strTVRegEx" ){
		$strDestFile="$dirWorkVolume\Outbox\TV\$strDestFileName"
	}
	else {
		$path = "$dirWorkVolume\Outbox\Movies\$strFilename"
		If(!(test-path $path))
		{
			out-file $outfile -Append -encoding OEM -inputObject "mkdir ""$dirWorkVolume\Outbox\Movies\$strFilename"""
		}
		$strDestFile = "$dirWorkVolume\Outbox\Movies\$strFilename\$strDestFileName"
	}
	out-file $outfile -Append -encoding OEM -inputObject "call transcode-video $strGeneralOpts $strVideoOpts $strAudioOptions $strSubOpts $strTestOpts --output ""$strDestFile"" ""$strSourceFile"""
	out-file $outfile -Append -encoding OEM -inputObject "mkvpropedit ""$strDestFile"" --edit info --set ""muxing-application=vtp_$intVersion"""
	out-file $outfile -Append -encoding OEM -inputObject "move ""$strSourceFile"" ""$dirArchive\$strArchFileName"""
	out-file $outfile -Append -encoding OEM -inputObject "move ""$strDestFile"" ""$strDestFile"""
	out-file $outfile -Append -encoding OEM -inputObject "move ""$strDestFile.log"" ""$dirEncodingLogs"""
	out-file $outfile -Append -encoding OEM -inputObject "DEL ""%~f0"""
	clear-variable -name strSubOpts
	clear-variable -name strAudioOptions
}

Write-Output "No files remain to be processed. Exiting..."
exit 0
