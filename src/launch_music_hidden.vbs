Option Explicit
Dim shell, fso, script, payload, index, command, shortcutKey, startIndex
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
script = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "launch_music_installed.ps1")
payload = "["
shortcutKey = ""
startIndex = 0
If WScript.Arguments.Count >= 2 Then
    If WScript.Arguments(0) = "--shortcut-key" Then
        shortcutKey = WScript.Arguments(1)
        startIndex = 2
    End If
End If
For index = startIndex To WScript.Arguments.Count - 1
    If index > startIndex Then payload = payload & ","
    payload = payload & JsonQuote(WScript.Arguments(index))
Next
payload = payload & "]"
command = NativeQuote(shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & NativeQuote(script) & " -ForwardArgsJson " & NativeQuote(payload)
If shortcutKey <> "" Then command = command & " -ShortcutKey " & NativeQuote(shortcutKey)
shell.Run command, 0, False

Function JsonQuote(value)
    Dim result, pos, number
    result = Chr(34)
    For pos = 1 To Len(value)
        number = AscW(Mid(value, pos, 1)) And &HFFFF
        result = result & "\u" & Right("0000" & Hex(number), 4)
    Next
    JsonQuote = result & Chr(34)
End Function

Function NativeQuote(value)
    Dim result, pos, character, slashes
    result = Chr(34)
    slashes = 0
    For pos = 1 To Len(value)
        character = Mid(value, pos, 1)
        If character = "\" Then
            slashes = slashes + 1
        Else
            If character = Chr(34) Then
                result = result & String(slashes * 2 + 1, "\") & character
            Else
                result = result & String(slashes, "\") & character
            End If
            slashes = 0
        End If
    Next
    NativeQuote = result & String(slashes * 2, "\") & Chr(34)
End Function
