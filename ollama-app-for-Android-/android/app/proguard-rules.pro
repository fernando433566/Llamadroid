# PDFBox can optionally decode JPEG 2000 through Gemalto's JP2 library.
# That decoder is not bundled; PDF text extraction and Android PdfRenderer do
# not require it. Keep R8 from treating the optional integration as mandatory.
-dontwarn com.gemalto.jp2.JP2Decoder
