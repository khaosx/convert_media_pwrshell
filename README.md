# convert_media.sh

Wrapper script written in powershell for batch control of video transcoding

v1.25.04

## Requires:
 
* [Don Melton's video transcoding gem](https://github.com/donmelton/video_transcoding)
		
## Notes:

The version number of this script will be tied to Don Melton's gem version (e.g. 1.25.1 will be script version 1, gem v .25, minor version 1), applicable to anything transcoded with version .25 or lower of Don's project. This is done to allow for quick ID of parameters used for media encoded with that version of the script.

## To create a queue

Create a Powershell script:

```
$drvData = get-volume -FileSystemLabel "Data"
$strRootVol = $drvData.DriveLetter
$dirWorkVolume = "$strRootVol`:\Workflows\Encoding\Queue"

if ( $Null -eq (get-process "handbrakecli" -ea SilentlyContinue )){
	$strCallCMD = Get-ChildItem $dirWorkVolume -Filter *.cmd -File -Name | Select-Object -First 1
	write-host $strCallCMD
	Invoke-Item "$dirWorkVolume\$strCallCMD"
}
exit 0

```

Add that script to Task Scheduler to run on a schedule (I run it every 120 seconds)
