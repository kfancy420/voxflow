# Generates a synthetic dictation test set next to this script:
#   clips\clipNN.wav  +  manifest.tsv  (wavPath <TAB> reference transcript)
#
# Sentences deliberately mix developer vocabulary, product proper nouns,
# numbers and business admin — the things a general dictation benchmark gets
# right and a real user's day gets wrong.

Add-Type -AssemblyName System.Speech

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir = Join-Path $root 'clips'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
    16000,
    [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
    [System.Speech.AudioFormat.AudioChannel]::Mono)

$sentences = @(
  'I want you to look at the performance and make sure that we are running optimally.',
  'Clone the repository and run dotnet publish with the self contained flag.',
  'The Whisper model now loads through Vulkan on the RTX five thousand eighty.',
  'Add a null check in TrayAppContext before we dereference the tray icon.',
  'Refactor the authentication middleware to use asynchronous handlers.',
  'The quarterly revenue forecast increased by seventeen percent year over year.',
  'Send an invoice to the client for the ninety minute deep tissue massage session.',
  'Schedule a follow up appointment for Tuesday afternoon at four thirty.',
  'The TypeScript build fails because the tsconfig paths are not resolving.',
  'Please summarize the transcript and extract the action items for me.'
)

# Installed voice names vary by machine; resolve them once and skip selection
# entirely if none are enumerable, rather than throwing per clip.
$probe = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voices = @($probe.GetInstalledVoices() |
    Where-Object { $_.Enabled } |
    ForEach-Object { $_.VoiceInfo.Name })
$probe.Dispose()
Write-Host ("voices available: " + ($(if ($voices.Count) { $voices -join ', ' } else { '(default only)' })))

$manifest = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $sentences.Count; $i++) {
    $path = Join-Path $dir ("clip{0:D2}.wav" -f ($i + 1))
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    if ($voices.Count -gt 0) {
        try { $synth.SelectVoice($voices[$i % $voices.Count]) } catch { }
    }
    $synth.Rate = 1   # slightly fast: closer to dictation than a reference read
    $synth.SetOutputToWaveFile($path, $fmt)
    $synth.Speak($sentences[$i])
    $synth.SetOutputToNull()
    $synth.Dispose()
    $manifest.Add($path + "`t" + $sentences[$i])
}

$manifestPath = Join-Path $root 'manifest.tsv'
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
Write-Host ("wrote {0} clips and {1}" -f $sentences.Count, $manifestPath)
