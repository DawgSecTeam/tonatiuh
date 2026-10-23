@echo off

SETLOCAL EnableDelayedExpansion
TITLE %~nx0

REM list em all
SC QUERY type= service state= all |findstr "SERVICE_NAME"

REM kill em all
SET "print="
FOR /f "usebackq delims=" %%G IN (`type "%~f0"`) DO (
	IF "%%G"==":HEREDOC_END" SET "print="	
	IF defined print (
		ECHO %%G
		REM SC config "%%G" start= disabled
		REM SC stop "%%G"
	)	
	IF "%%G"==":HEREDOC_START" SET "print=1"
)
ENDLOCAL
GOTO :eof

:HEREDOC_START
Am I glad he's in there and we're out here
ayy
lmao
windows 11
:HEREDOC_END
