module Util.Handler where

import Import
import qualified Data.CaseInsensitive as CI
import qualified Data.Text.Encoding as TE
import Yesod.Markdown
import Text.Pandoc (MetaValue(..),Inline(..), writerExtensions,writerWrapText, WrapOption(..), readerExtensions, Pandoc(..))
import Text.Pandoc.Walk (walkM, walk)
import Text.Julius (juliusFile,rawJS)
import Text.Hamlet (hamletFile)
import TH.RelativePaths (pathRelativeToCabalPackage)
import Util.Data
import Util.Database

minimalLayout c = [whamlet|
                  <div.container>
                      <article>
                          #{c}
                  |]

cleanLayout widget = do
        master <- getYesod
        mmsg <- getMessage
        authmaybe <- maybeAuth
        (mud, mdoc, mcourse) <- case entityKey <$> authmaybe of
            Nothing -> return (Nothing, Nothing, Nothing)
            Just uid -> do
                mud <- maybeUserData
                runDB $ do
                    mcour <- maybe (return Nothing) get (mud >>= userDataEnrolledIn . entityVal)
                    masgn <- maybe (return Nothing) get (mcour >>= courseTextBook)
                    mdoc <- maybe (return Nothing) get (assignmentMetadataDocument <$> masgn)
                    return (mud, mdoc, mcour)
        let isInstructor = not $ null (mud >>= userDataInstructorId . entityVal)
        pc <- widgetToPageContent $(widgetFile "default-layout")
        withUrlRenderer $(hamletFile =<< pathRelativeToCabalPackage "templates/default-layout-wrapper.hamlet")

retrievePandocVal metaval = case metaval of 
                        Just (MetaInlines ils) -> return $ Just (catMaybes (map fromStr ils))
                        Just (MetaList list) -> do mcsses <- mapM retrievePandocVal (map Just list) 
                                                   return . Just . concat . catMaybes $ mcsses
                        Nothing -> return Nothing
                        x -> setMessage (toHtml ("bad yaml metadata: " ++ show x)) >> return Nothing
    where fromStr (Str x) = Just x
          fromStr _ = Nothing

fileToHtml filters path = do Markdown md <- markdownFromFile path
                             let md' = Markdown (filter ((/=) '\r') md) --remove carrage returns from dos files
                             case parseMarkdown yesodDefaultReaderOptions { readerExtensions = carnapPandocExtensions } md' of
                                 Right pd -> do let pd'@(Pandoc meta _)= walk filters pd
                                                return $ Right $ (write pd', meta)
                                 Left e -> return $ Left e
    where write = writePandocTrusted yesodDefaultWriterOptions { writerExtensions = carnapPandocExtensions, writerWrapText = WrapPreserve }

serveDoc :: (Document -> FilePath -> Handler a) -> Document -> FilePath -> UserId -> Handler a
serveDoc sendIt doc path creatoruid = case documentScope doc of 
                                Private -> do
                                  muid <- maybeAuthId
                                  case muid of Just uid' | uid' == creatoruid -> sendIt doc path
                                               _ -> notFound
                                _ -> sendIt doc path

asFile :: Document -> FilePath -> Handler TypedContent
asFile doc path = do addHeader "Content-Disposition" $ concat
                        [ "attachment;"
                        , "filename=\"", documentFilename doc, "\""
                        ]
                     sendFile typeOctet path

asCss :: Document -> FilePath -> Handler TypedContent
asCss _ path = sendFile typeCss path

asJs :: Document -> FilePath -> Handler TypedContent
asJs _ path = sendFile typeJavascript path
