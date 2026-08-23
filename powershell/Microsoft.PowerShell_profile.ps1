Set-PSReadLineOption -EditMode Windows
Set-PSReadLineKeyHandler -Chord 'Ctrl+Insert' -Function Copy
Set-PSReadLineKeyHandler -Chord 'Tab' -Function AcceptSuggestion
Set-PSReadLineKeyHandler -Chord 'RightArrow' -Function TabCompleteNext
function cf { Set-Location "D:\Programming\CoinFlipper" }

function svr { Set-Location "D:\Video Upscaling\SeedVr" }

function br { . $PROFILE }

# Report cwd to Windows Terminal (OSC 9;9) so duplicate-tab/split-pane keep the folder.
function prompt {
    $loc = $executionContext.SessionState.Path.CurrentLocation
    $out = ""
    if ($loc.Provider.Name -eq "FileSystem") {
        $out += "$([char]27)]9;9;`"$($loc.ProviderPath)`"$([char]27)\"
    }
    $out += "PS $loc$('>' * ($nestedPromptLevel + 1)) "
    return $out
}
