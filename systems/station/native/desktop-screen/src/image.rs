// Pictures as files, with WIC: a JPEG of the screen (quality 0.8, as the Mac's), PNGs to and from the clipboard.
use windows::Win32::Graphics::Gdi::HBITMAP;
use windows::Win32::Graphics::Imaging::*;
use windows::Win32::System::Com::StructuredStorage::{IPropertyBag2, PROPBAG2};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance, IStream, STREAM_SEEK_CUR, STREAM_SEEK_SET};
use windows::Win32::System::Variant::{VARIANT, VT_R4};
use windows::Win32::UI::Shell::SHCreateMemStream;
use windows::core::{GUID, Interface, Result, w};

pub struct Images {
    factory: IWICImagingFactory,
}

/// BGRA pixels: rows of `pitch` bytes.
pub struct Pixels<'a> {
    pub width: u32,
    pub height: u32,
    pub pitch: u32,
    pub bytes: &'a [u8],
}

impl Images {
    pub fn new() -> Result<Images> {
        Ok(Images { factory: unsafe { CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)? } })
    }

    fn encode(&self, container: &GUID, source: &IWICBitmapSource, quality: Option<f32>) -> Result<Vec<u8>> {
        unsafe {
            let stream = SHCreateMemStream(None).ok_or_else(|| windows::core::Error::from_thread())?;
            let encoder = self.factory.CreateEncoder(container, std::ptr::null())?;
            encoder.Initialize(&stream, WICBitmapEncoderNoCache)?;
            let mut frame = None;
            let mut options: Option<IPropertyBag2> = None;
            encoder.CreateNewFrame(&mut frame, &mut options)?;
            let frame = frame.unwrap();
            if let (Some(quality), Some(options)) = (quality, options.as_ref()) {
                let name = PROPBAG2 { pstrName: windows::core::PWSTR(w!("ImageQuality").as_ptr() as *mut u16), vt: VT_R4, ..Default::default() };
                let _ = options.Write(1, &name, &VARIANT::from(quality));
            }
            frame.Initialize(options.as_ref())?;
            let (mut width, mut height) = (0, 0);
            source.GetSize(&mut width, &mut height)?;
            frame.SetSize(width, height)?;
            // WriteSource converts to the format the encoder takes.
            frame.WriteSource(source, std::ptr::null())?;
            frame.Commit()?;
            encoder.Commit()?;
            read_all(&stream)
        }
    }

    pub fn jpeg(&self, pixels: &Pixels) -> Result<Vec<u8>> {
        // Without its alpha (a screen's is not one): BGRA read as BGR with a byte unused.
        let length = (pixels.pitch * pixels.height) as usize;
        let bitmap = unsafe { self.factory.CreateBitmapFromMemory(pixels.width, pixels.height, &GUID_WICPixelFormat32bppBGR, pixels.pitch, &pixels.bytes[..length])? };
        self.encode(&GUID_ContainerFormatJpeg, &bitmap.cast()?, Some(0.8))
    }

    /// A bitmap of the clipboard's as a PNG.
    pub fn png_of_hbitmap(&self, bitmap: HBITMAP) -> Result<Vec<u8>> {
        let source = unsafe { self.factory.CreateBitmapFromHBITMAP(bitmap, Default::default(), WICBitmapIgnoreAlpha)? };
        self.encode(&GUID_ContainerFormatPng, &source.cast()?, None)
    }

    /// A picture's pixels, BGRA, top row first: (width, height, bytes).
    pub fn decode(&self, file: &[u8]) -> Result<(u32, u32, Vec<u8>)> {
        unsafe {
            let stream = SHCreateMemStream(Some(file)).ok_or_else(|| windows::core::Error::from_thread())?;
            let decoder = self.factory.CreateDecoderFromStream(&stream, std::ptr::null(), WICDecodeMetadataCacheOnDemand)?;
            let frame = decoder.GetFrame(0)?;
            let converter = self.factory.CreateFormatConverter()?;
            converter.Initialize(&frame, &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, None, 0.0, WICBitmapPaletteTypeCustom)?;
            let (mut width, mut height) = (0, 0);
            converter.GetSize(&mut width, &mut height)?;
            let mut bytes = vec![0u8; (width * height * 4) as usize];
            converter.CopyPixels(std::ptr::null(), width * 4, &mut bytes)?;
            Ok((width, height, bytes))
        }
    }
}

fn read_all(stream: &IStream) -> Result<Vec<u8>> {
    unsafe {
        let mut length = 0u64;
        stream.Seek(0, STREAM_SEEK_CUR, Some(&mut length))?;
        stream.Seek(0, STREAM_SEEK_SET, None)?;
        let mut bytes = vec![0u8; length as usize];
        let mut read = 0u32;
        stream.Read(bytes.as_mut_ptr() as _, length as u32, Some(&mut read)).ok()?;
        bytes.truncate(read as usize);
        Ok(bytes)
    }
}
