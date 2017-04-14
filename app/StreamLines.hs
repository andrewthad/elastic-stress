{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module StreamLines where

import qualified Data.ByteString as B 
import qualified Data.ByteString.Internal as B
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Char8 as Char8
import Data.ByteString.Internal (c2w,w2c)

import Streaming hiding (concats, unfold, distribute, mwrap)
import Streaming.Internal (Stream (..))
import Data.ByteString.Streaming.Internal

{- | 'lineSplit' turns a ByteString into a connected stream of ByteStrings at
     divide after a fixed number of newline characters. 
     Unlike most of the string splitting functions in this library, 
     this function preserves newlines characters. 

     Like 'lines', this function properly handles both @\\n@ and @\\r\\n@
     endings regardless of the current platform.
     
     >>> let planets = ["Mercury","Venus","Earth","Mars","Saturn","Jupiter","Neptune","Uranus"]
     >>> S.mapsM_ (\x -> putStrLn "Chunk" >> Q.putStrLn x) $ Q.lineSplit 3 $ Q.string $ L.unlines planets
     Chunk
     Mercury
     Venus
     Earth

     Chunk
     Mars
     Saturn
     Jupiter

     Chunk
     Neptune
     Uranus

-}
lineSplit :: forall m r. Monad m 
  => Int -- ^ number of lines per group
  -> ByteString m r -- ^ stream of bytes
  -> Stream (ByteString m) m r
lineSplit !n0 text0 = loop1 0 text0
  where
    n :: Int
    !n = max n0 1
    loop1 :: Int -> ByteString m r -> Stream (ByteString m) m r
    loop1 !counter text =
      case text of
        Empty r -> Return r
        Go m -> Effect $ liftM (loop1 counter) m
        Chunk c cs
          | B.null c -> loop1 counter cs
          | otherwise -> Step (loop2 counter text)
    loop2 :: Int -> ByteString m r -> ByteString m (Stream (ByteString m) m r)
    loop2 !counter text =
      case text of
        Empty r -> Empty (Return r)
        Go m -> Go $ liftM (loop2 counter) m
        Chunk c cs ->
          let !numNewlines = B.count 10 c
              !newCounter = counter + numNewlines
           in if newCounter >= n
                then case drop (n - counter - 1) (B.findIndices (== 10) c) of
                  i : _ -> 
                    let !j = i + 1
                     in Chunk (B.unsafeTake j c) (Empty (loop1 0 (Chunk (B.unsafeDrop j c) cs)))
                  -- the empty list cannot happen unless Data.ByteString.count or
                  -- Data.ByteString.findIndices is misimplemented. The expression
                  -- that handles this case is only here to satisfy the type
                  -- checker.
                  [] -> loop2 0 cs 
                else Chunk c (loop2 newCounter cs)
{-#INLINABLE lineSplit #-}
