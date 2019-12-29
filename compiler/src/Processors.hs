-- ldgallery - A static generator which turns a collection of tagged
--             pictures into a searchable web gallery.
--
-- Copyright (C) 2019  Pacien TRAN-GIRARD
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

{-# LANGUAGE
    DuplicateRecordFields
  , DeriveGeneric
  , DeriveAnyClass
  , FlexibleContexts
#-}

module Processors
  ( Resolution(..)
  , DirFileProcessor, dirFileProcessor
  , ItemFileProcessor, itemFileProcessor
  , ThumbnailFileProcessor, thumbnailFileProcessor
  , skipCached, withCached
  ) where


import Control.Exception (Exception, throwIO)
import Data.Function ((&))
import Data.Ratio ((%))
import Data.Char (toLower)

import GHC.Generics (Generic)
import Data.Aeson (FromJSON)

import System.Directory hiding (copyFile)
import qualified System.Directory
import System.FilePath

import Codec.Picture
import Codec.Picture.Extra -- TODO: compare DCT and bilinear (and Lanczos, but it's not implemented)

import Resource
import Files


data ProcessingException = ProcessingException FilePath String deriving Show
instance Exception ProcessingException

data Format =
    Bmp | Jpg | Png | Tiff | Hdr -- static images
  | Gif -- TODO: might be animated
  | Other

formatFromExt :: String -> Format
formatFromExt = aux . (map toLower)
  where
    aux ".bmp" = Bmp
    aux ".jpg" = Jpg
    aux ".jpeg" = Jpg
    aux ".png" = Png
    aux ".tiff" = Tiff
    aux ".hdr" = Hdr
    aux ".gif" = Gif
    aux _ = Other

data Resolution = Resolution
  { width :: Int
  , height :: Int } deriving (Show, Generic, FromJSON)

type FileProcessor =
     FileName        -- ^ Input path
  -> FileName        -- ^ Output path
  -> IO ()

copyFileProcessor :: FileProcessor
copyFileProcessor inputPath outputPath =
  (putStrLn $ "Copying:\t" ++ outputPath)
  >> ensureParentDir (flip System.Directory.copyFile) outputPath inputPath

resizeStaticImageUpTo :: Format -> Resolution -> FileProcessor
resizeStaticImageUpTo Bmp = resizeStaticGeneric readBitmap saveBmpImage
-- TODO: parameterise export quality for jpg
resizeStaticImageUpTo Jpg = resizeStaticGeneric readJpeg (saveJpgImage 80)
resizeStaticImageUpTo Png = resizeStaticGeneric readPng savePngImage
resizeStaticImageUpTo Tiff = resizeStaticGeneric readTiff saveTiffImage
resizeStaticImageUpTo Hdr = resizeStaticGeneric readHDR saveRadianceImage
resizeStaticImageUpTo Gif = resizeStaticGeneric readGif writeGifImage
  where
    writeGifImage :: StaticImageWriter
    writeGifImage outputPath image =
      saveGifImage outputPath image
      & either (throwIO . ProcessingException outputPath) id


type StaticImageReader = FilePath -> IO (Either String DynamicImage)
type StaticImageWriter = FilePath -> DynamicImage -> IO ()

resizeStaticGeneric :: StaticImageReader -> StaticImageWriter -> Resolution -> FileProcessor
resizeStaticGeneric reader writer maxRes inputPath outputPath =
  (putStrLn $ "Generating:\t" ++ outputPath)
  >>  reader inputPath
  >>= either (throwIO . ProcessingException inputPath) return
  >>= return . (fitDynamicImage maxRes)
  >>= ensureParentDir writer outputPath

fitDynamicImage :: Resolution -> DynamicImage -> DynamicImage
fitDynamicImage (Resolution boxWidth boxHeight) image =
  convertRGBA8 image
  & scaleBilinear targetWidth targetHeight
  & ImageRGBA8
  where
    picWidth = dynamicMap imageWidth image
    picHeight = dynamicMap imageHeight image
    resizeRatio = min (boxWidth % picWidth) (boxHeight % picHeight)
    targetWidth = floor $ resizeRatio * (picWidth % 1)
    targetHeight = floor $ resizeRatio * (picHeight % 1)


type Cache = FileProcessor -> FileProcessor

skipCached :: Cache
skipCached processor inputPath outputPath =
  removePathForcibly outputPath
  >> processor inputPath outputPath

withCached :: Cache
withCached processor inputPath outputPath =
  do
    isDir <- doesDirectoryExist outputPath
    if isDir then removePathForcibly outputPath else noop

    fileExists <- doesFileExist outputPath
    if fileExists then
      do
        needUpdate <- isOutdated inputPath outputPath
        if needUpdate then update else skip
    else
      update

  where
    noop = return ()
    update = processor inputPath outputPath
    skip = putStrLn $ "Skipping:\t" ++ outputPath


type DirFileProcessor =
     FileName        -- ^ Input base path
  -> FileName        -- ^ Output base path
  -> FileName        -- ^ Output class (subdir)
  -> DirProcessor

dirFileProcessor :: DirFileProcessor
dirFileProcessor _ _ = (.) return . (/>)


type ItemFileProcessor =
     FileName        -- ^ Input base path
  -> FileName        -- ^ Output base path
  -> FileName        -- ^ Output class (subdir)
  -> ItemProcessor

itemFileProcessor :: Maybe Resolution -> Cache -> ItemFileProcessor
itemFileProcessor maxRes cached inputBase outputBase resClass inputRes =
  cached (processor maxRes (extOf inputRes)) inPath outPath
  >> return relOutPath
  where
    extOf = formatFromExt . takeExtension . head
    relOutPath = resClass /> inputRes
    inPath = localPath $ inputBase /> inputRes
    outPath = localPath $ outputBase /> relOutPath

    processor :: Maybe Resolution -> Format -> FileProcessor
    processor Nothing _ = copyFileProcessor
    processor (Just maxRes) Bmp = resizeStaticImageUpTo Bmp maxRes
    processor (Just maxRes) Jpg = resizeStaticImageUpTo Jpg maxRes
    processor (Just maxRes) Png = resizeStaticImageUpTo Png maxRes
    processor (Just maxRes) Tiff = resizeStaticImageUpTo Tiff maxRes
    processor (Just maxRes) Hdr = resizeStaticImageUpTo Hdr maxRes
    processor _ Gif = copyFileProcessor -- TODO: handle animated gif resizing
    processor _ Other = copyFileProcessor -- TODO: handle video reencoding and others?


type ThumbnailFileProcessor =
     FileName        -- ^ Input base path
  -> FileName        -- ^ Output base path
  -> FileName        -- ^ Output class (subdir)
  -> ThumbnailProcessor

thumbnailFileProcessor :: Resolution -> Cache -> ThumbnailFileProcessor
thumbnailFileProcessor maxRes cached inputBase outputBase resClass inputRes =
  cached <$> processor (extOf inputRes)
  & process
  where
    extOf = formatFromExt . takeExtension . head
    relOutPath = resClass /> inputRes
    inPath = localPath $ inputBase /> inputRes
    outPath = localPath $ outputBase /> relOutPath

    process :: Maybe FileProcessor -> IO (Maybe Path)
    process Nothing = return Nothing
    process (Just processor) =
      processor inPath outPath
      >> return (Just relOutPath)

    processor :: Format -> Maybe FileProcessor
    processor Bmp = Just $ resizeStaticImageUpTo Bmp maxRes
    processor Jpg = Just $ resizeStaticImageUpTo Jpg maxRes
    processor Png = Just $ resizeStaticImageUpTo Png maxRes
    processor Tiff = Just $ resizeStaticImageUpTo Tiff maxRes
    processor Hdr = Just $ resizeStaticImageUpTo Hdr maxRes
    processor Gif = Just $ resizeStaticImageUpTo Gif maxRes -- static thumbnail from first frame
    processor _ = Nothing
