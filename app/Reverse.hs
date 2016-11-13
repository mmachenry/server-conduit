import Data.Conduit.Network.Server
import qualified Data.ByteString as B
import Data.Attoparsec.ByteString (takeTill)
import Data.Attoparsec.ByteString.Char8 (isEndOfLine, endOfLine)

main = oneToOneServer 4444 (takeTill isEndOfLine <* endOfLine) B.reverse

