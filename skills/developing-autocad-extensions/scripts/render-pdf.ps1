# Renders one page of a PDF to a PNG with Windows' built-in PDF API, so a plot
# can be looked at with no PDF tools installed. Written for Windows PowerShell 5.1.
#
# Usage: render-pdf.ps1 <pdf> <png> [-Width <pixels>] [-Page <number>]
#   -Width  output width in pixels (default 2000); the height keeps the page's proportions
#   -Page   1-based page number (default 1)
# Prints the page count and the page size, which is in 1/96-inch units, not points.

param([string]$Pdf, [string]$Png, [int]$Width = 2000, [int]$Page = 1)

trap { [Console]::Error.WriteLine("render-pdf: $($_.Exception.Message)"); exit 1 }
$ErrorActionPreference = 'Stop'
if (-not $Pdf -or -not $Png) { throw 'usage: render-pdf.ps1 <pdf> <png> [-Width <pixels>] [-Page <number>]' }
# The WinRT calls need absolute paths.
$Pdf = (Resolve-Path -LiteralPath $Pdf).ProviderPath
$Png = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Png))

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]

# PowerShell can't await WinRT operations, so convert them to .NET tasks and wait.
$asTaskMethods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
$asTaskForResult = $asTaskMethods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asTaskForAction = $asTaskMethods | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Wait-Result($operation, [Type]$resultType) {
    $task = $asTaskForResult.MakeGenericMethod($resultType).Invoke($null, @($operation)); $task.Wait(); $task.Result
}
function Wait-Action($action) { $asTaskForAction.Invoke($null, @($action)).Wait() }

$file = Wait-Result ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Pdf)) ([Windows.Storage.StorageFile])
$document = Wait-Result ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
if ($Page -lt 1 -or $Page -gt $document.PageCount) { throw "page $Page is out of range (the PDF has $($document.PageCount))" }
$pdfPage = $document.GetPage($Page - 1)

$options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
$options.DestinationWidth = $Width
$options.DestinationHeight = [uint32]($Width * $pdfPage.Size.Height / $pdfPage.Size.Width)
$options.BackgroundColor = [Windows.UI.Color]::FromArgb(255, 255, 255, 255)
$stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
Wait-Action ($pdfPage.RenderToStreamAsync($stream, $options))

$source = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($stream.GetInputStreamAt(0))
$target = [IO.File]::Create($Png)
try { $source.CopyTo($target) } finally { $target.Close() }
"pages=$($document.PageCount) size=$($pdfPage.Size.Width)x$($pdfPage.Size.Height)"
