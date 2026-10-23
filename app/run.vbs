' Starts a ClipToast PowerShell script with no visible console window.
' Usage: wscript.exe run.vbs <script.ps1> [extra args]
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = "downloader.ps1"
If WScript.Arguments.Count > 0 Then script = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\" & script & """"
For i = 1 To WScript.Arguments.Count - 1
  arg = WScript.Arguments(i)
  If InStr(arg, " ") > 0 And Left(arg, 1) <> """" Then
    cmd = cmd & " """ & arg & """"
  Else
    cmd = cmd & " " & arg
  End If
Next
CreateObject("WScript.Shell").Run cmd, 0, False
