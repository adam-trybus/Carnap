{-#LANGUAGE FlexibleContexts, RankNTypes #-}
module Carnap.GHCJS.Action.CounterModel (counterModelAction) where

import Lib
import Carnap.GHCJS.SharedTypes
import Carnap.Core.Data.Types (Form(..), Term(..), Arity(..), Fix(..), arityInt)
import Carnap.Core.Data.Classes
import Carnap.Core.Data.Util
import Carnap.Languages.Util.LanguageClasses
import Carnap.Languages.PureFirstOrder.Logic 
import Carnap.Languages.PureFirstOrder.Semantics
import Carnap.Languages.PureFirstOrder.Syntax
import Carnap.Languages.PureFirstOrder.Util (universalClosure)
import Carnap.Languages.ClassicalSequent.Syntax
import Carnap.Calculi.NaturalDeduction.Syntax (NaturalDeductionCalc(..))
import GHCJS.DOM.Types
import GHCJS.DOM.Element
import GHCJS.DOM.Event (initEvent)
import GHCJS.DOM.EventTarget (dispatchEvent)
import GHCJS.DOM.Document (createElement, createEvent, getDefaultView)
import GHCJS.DOM.Node (appendChild, getParentNode, insertBefore)
import GHCJS.DOM.EventM (newListener, addListener, EventM, target)
import GHCJS.DOM.HTMLTextAreaElement (castToHTMLTextAreaElement, setValue, getValue)
import qualified GHCJS.DOM.HTMLSelectElement as S (getValue, setValue) 
import Text.Parsec
import Data.Typeable (Typeable)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Either (isLeft,isRight)
import Data.Map as M (Map, lookup, foldr, insert, fromList, toList)
import Data.IORef (newIORef, IORef, readIORef,writeIORef, modifyIORef)
import Data.List (intercalate)
import Data.Text (pack)
import Control.Monad (filterM)
import Control.Monad.IO.Class (liftIO)
import Control.Lens

counterModelAction :: IO ()
counterModelAction = initElements getCounterModelers activateCounterModeler

getCounterModelers :: Document -> HTMLElement -> IO [Maybe (Element, Element, Map String String)]
getCounterModelers d = genInOutElts d "div" "div" "countermodeler"

activateCounterModeler :: Document -> Maybe (Element, Element, Map String String) -> IO ()
activateCounterModeler w (Just (i,o,opts)) = do
        case M.lookup "countermodelertype" opts of
            Just "simple" -> checkerWith (formListParser <* eof) createSimpleCounterModeler
            Just "constraint" -> checkerWith (formListPairParser <* eof) createConstrainedCounterModeler
            Just "validity" -> checkerWith (seqParser <* eof) createValidityCounterModeler
            _  -> return ()
    where (formParser,seqParser) = case M.lookup "system" opts >>= \sys -> (,) <$> ndParseForm `ofFOLSys` sys <*> ndParseSeq `ofFOLSys` sys of
                                         Just pair -> pair
                                         Nothing -> let Just fp = ndParseForm `ofFOLSys` "firstOrder"
                                                        Just sp = ndParseSeq `ofFOLSys` "firstOrder"
                                                        in (fp,sp)
          formListParser = formParser `sepEndBy1` (spaces *> char ',' <* spaces)
          formListPairParser = do gs <- try (formListParser <* char ':') <|> return []
                                  optional (char ':')
                                  spaces
                                  fs <- formListParser
                                  return (gs,fs)
          
          checkerWith parser cmbuilder = 
            case M.lookup "goal" opts of
                Just g ->
                  case parse parser "" g of
                      Left e -> setInnerHTML o (Just $ show e) 
                      Right f -> do
                          ref <- newIORef $ Left "Please press submit to check your answer"
                          bw <- buttonWrapper w
                          check <- cmbuilder w f (i,o) bw opts
                          fields <- catMaybes <$> getListOfElementsByTag o "label"
                          mapM (setField w fields) (makeGivens opts)
                          case M.lookup "submission" opts of
                              Just s | take 7 s == "saveAs:" -> do
                                  let l = Prelude.drop 7 s
                                  bt1 <- doneButton w "Submit"
                                  appendChild bw (Just bt1)
                                  submit <- newListener $ submitCounterModel opts ref check fields (show f) l
                                  addListener bt1 click submit False                
                              _ -> return ()
                          if "nocheck" `inOpts` opts then return () 
                          else do
                              bt2 <- questionButton w "Check"
                              appendChild bw (Just bt2)
                              checkIt <- newListener $ checkCounterModeler ref fields check
                              addListener bt2 click checkIt False                
                          Just par <- getParentNode o
                          appendChild par (Just bw)
                          return ()
                _ -> print "countermodeler lacks a goal"

          checkCounterModeler ref fields check = do validated <- liftIO $ validateModel fields
                                                    correct <- liftIO check
                                                    case (correct, validated) of 
                                                       (_,Left err) -> do
                                                           liftIO $ writeIORef ref (Left err)
                                                           message err
                                                           setAttribute i "class" "input incompleteCM"
                                                       (Left err,_) -> do
                                                           liftIO $ writeIORef ref (Left err)
                                                           message err
                                                           setAttribute i "class" "input incompleteCM"
                                                       _ -> do
                                                           liftIO $ writeIORef ref correct
                                                           message "Success!"
                                                           setAttribute i "class" "input completeCM"

submitCounterModel:: Map String String -> IORef (Either String ())->  IO (Either String ())-> [Element] -> String -> String -> EventM HTMLTextAreaElement e ()
submitCounterModel opts ref check fields s l = do isDone <- liftIO $ readIORef ref
                                                  case isDone of
                                                      Right _ -> trySubmit CounterModel opts l (ProblemContent (pack s)) True
                                                      Left err | not ("exam" `inOpts` opts) -> message err
                                                      _ -> do correct <- liftIO check
                                                              validated <- liftIO $ validateModel fields
                                                              case (correct, validated) of
                                                                 (Right _, Right _) -> trySubmit CounterModel opts l (ProblemContent (pack s)) True
                                                                 _ -> do extracted <- liftIO $ mapM extractField fields
                                                                         trySubmit CounterModel opts l (CounterModelDataOpts (pack s) extracted (M.toList opts)) False

createSimpleCounterModeler :: Document -> [PureFOLForm] -> (Element,Element)
    -> Element -> Map String String 
    -> IO (IO (Either String ()))
createSimpleCounterModeler w fs (i,o) bw opts = 
        do setInnerHTML i (Just . intercalate ", " . map (rewriteWith opts . show) $ fs)
           theModel <- initModel
           prepareModelUI w fs (i,o) theModel bw opts
           case M.lookup "counterexample-to" opts of
               Just "equivalence" -> return (counter theModel equiv)
               Just "tautology" -> return (counter theModel falsey)
               Just "validity" -> return (counter theModel falsey)
               Just "inconsistency" -> return (counter theModel truthful)
               _ -> return (counter theModel truthful)
    where counter mdl check = do
              m <- readIORef mdl
              let tvs = map (unform . satisfies m . universalClosure) fs
              return $ check tvs
          truthful tvs | and tvs = Right ()
                       | otherwise = do let falses = intercalate ", " $ map (rewriteWith opts . show . snd) . filter (not . fst) $ (zip tvs fs)
                                        Left $ "Not all formulas are true in this model. Take another look at: " ++  falses ++ "."
          falsey tvs | and (map not tvs) = Right ()
                     | otherwise = do let trues = intercalate ", " $ map (rewriteWith opts . show . snd) . filter fst $ (zip tvs fs)
                                      Left $ "Not all formulas are false in this model. Take another look at: " ++  trues ++ "."
          equiv tvs | and tvs = Left "Not a counterexample to equivalence - all formulas are true in this model."
                    | and (map not tvs) = Left "Not a counterexample to equivalence - all formulas are false in this model."
                    | otherwise = Right ()

createConstrainedCounterModeler :: Document -> ([PureFOLForm],[PureFOLForm]) -> (Element,Element)
    -> Element -> Map String String 
    -> IO (IO (Either String ()))
createConstrainedCounterModeler w (cs,fs) (i,o) bw opts = 
        do setInnerHTML i (Just . intercalate ", " . map (rewriteWith opts . show) $ fs)
           theModel <- initModel
           prepareModelUI w (cs ++ fs) (i,o) theModel bw opts
           case M.lookup "counterexample-to" opts of
               Just "equivalence" -> return (counter theModel equiv)
               Just "tautology" -> return (counter theModel falsey)
               Just "validity" -> return (counter theModel falsey)
               Just "inconsistency" -> return (counter theModel truthful)
               _ -> return (counter theModel truthful)
    where counter mdl check = do
              m <- readIORef mdl
              let tvs = map (unform . satisfies m . universalClosure) fs
              let ctvs = map (unform . satisfies m . universalClosure) cs
              if not (and ctvs) then return $ Left "Not all the constraints for this problem are satisfied by this model."
                                else return $ check tvs
          truthful tvs | and tvs = Right ()
                       | otherwise = do let falses = intercalate ", " $ map (rewriteWith opts . show . snd) . filter (not . fst) $ (zip tvs fs)
                                        Left $ "Not all formulas are true in this model. Take another look at: " ++  falses ++ "."
          falsey tvs | and (map not tvs) = Right ()
                     | otherwise = do let trues = intercalate ", " $ map (rewriteWith opts . show . snd) . filter fst $ (zip tvs fs)
                                      Left $ "Not all formulas are false in this model. Take another look at: " ++  trues ++ "."
          equiv tvs | and tvs = Left "Not a counterexample to equivalence - all formulas are true in this model."
                    | and (map not tvs) = Left "Not a counterexample to equivalence - all formulas are false in this model."
                    | otherwise = Right ()

createValidityCounterModeler :: Document -> ClassicalSequentOver PureLexiconFOL (Sequent (Form Bool)) -> (Element,Element) 
    -> Element -> Map String String 
    -> IO (IO (Either String ()))
createValidityCounterModeler w seq@(antced :|-: succed) (i,o) bw opts = 
        do setInnerHTML i (Just . rewriteWith opts . show $ seq)
           theModel <- initModel
           prepareModelUI w fs (i,o) theModel bw opts
           case M.lookup "counterexample-to" opts of
               Just "equivalence" -> return (counter theModel equiv)
               Just "tautology" -> return (counter theModel falsey)
               Just "validity" -> return (counter theModel falsey)
               Just "inconsistency" -> return (counter theModel truthful)
               _ -> return (counter theModel falsey)
    where ants = map fromSequent $ toListOf concretes antced
          sucs = map fromSequent $ toListOf concretes succed
          fs = ants ++ sucs
          counter mdl check = do
              m <- readIORef mdl
              let ptvs = map (unform . satisfies m . universalClosure) ants
                  ctvs = map (unform . satisfies m . universalClosure) sucs
              if not (and ptvs) then do 
                 let falses = intercalate ", " $ map (rewriteWith opts . show . snd) . filter (not . fst) $ (zip ptvs ants)
                 return $ Left $ "not all premises are true in this model. Take another look at: " ++ falses ++ "."
              else return $ check ctvs
          truthful tvs | and tvs = Right ()
                       | otherwise = do let falses = intercalate ", " $ map (rewriteWith opts . show . snd) . filter (not . fst) $ (zip tvs sucs)
                                        Left $ "Not all conclusions are true in this model. Take another look at: " ++  falses ++ "."
          falsey tvs | and (map not tvs) = Right ()
                     | otherwise = do let trues = intercalate ", " $ map (rewriteWith opts . show . snd) . filter fst $ (zip tvs sucs)
                                      Left $ "Not all conclusions are false in this model. Take another look at: " ++  trues ++ "."
          equiv tvs | and tvs = Left "Not a counterexample to equivalence - all conclusions are true in this model."
                    | and (map not tvs) = Left "Not a counterexample to equivalence - all conclusions are false in this model."
                    | otherwise = Right ()

prepareModelUI :: Document -> [PureFOLForm] -> (Element,Element) -> IORef PolyadicModel
    -> Element -> Map String String 
    -> IO ()
prepareModelUI w fs (i,o) mdl bw opts = do
           Just domainLabel <- createElement w (Just "label")
           setInnerHTML domainLabel (Just "Domain: ")
           (domainInput,domainWarn) <- parsingInput w things domainUpdater
           setAttribute domainInput "name" "Domain"
           setAttribute domainInput "rows" "1"
           setValue (castToHTMLTextAreaElement domainInput) (Just "0")
           mapM (appendChild domainLabel . Just) [domainInput, domainWarn]
           appendChild o (Just domainLabel)
           appendRelationInputs w o fs mdl
           appendPropInputs w o fs mdl
           let ts = concatMap (toListOf termsOf) fs
           appendConstantInputs w o ts mdl
           appendFunctionInputs w o ts mdl
    where domainUpdater ts = liftIO $ modifyIORef mdl (\m -> m { monadicPart = (monadicPart m) {domain = ts}})
          things = parseInt `sepEndBy1` (spaces *> char ',' <* spaces)

appendRelationInputs :: Document -> Element -> [PureFOLForm] -> IORef PolyadicModel -> IO ()
appendRelationInputs w o fs mdl = do let sfs = nub . concatMap (map blankTerms . universe) $ fs
                                     mapM_ appendRelationInput sfs
    where appendRelationInput f = do minput <- getRelationInput w f mdl
                                     case minput of 
                                        Nothing -> return Nothing
                                        Just input -> appendChild o (Just input)

appendFunctionInputs :: Document -> Element -> [PureFOLTerm] -> IORef PolyadicModel -> IO ()
appendFunctionInputs w o fs mdl = do let sfs = nub . concatMap (map blankFuncTerms . universe) $ fs
                                     mapM_ appendFunctionInput sfs
    where appendFunctionInput f = do minput <- getFunctionInput w f mdl
                                     case minput of 
                                        Nothing -> return Nothing
                                        Just input -> appendChild o (Just input)

appendConstantInputs :: Document -> Element -> [PureFOLTerm] -> IORef PolyadicModel -> IO ()
appendConstantInputs w o ts mdl = do let sts = nub . concatMap universe $ ts
                                     mapM_ appendConstantInput sts
    where appendConstantInput t = do minput <- getConstInput w t mdl
                                     case minput of 
                                        Nothing -> return Nothing
                                        Just input -> appendChild o (Just input)

appendPropInputs :: Document -> Element -> [PureFOLForm] -> IORef PolyadicModel -> IO ()
appendPropInputs w o fs mdl = do let sfs = nub . concatMap universe $ fs
                                 mapM_ appendPropInput sfs
    where appendPropInput t = do minput <- getPropInput w t mdl
                                 case minput of 
                                    Nothing -> return Nothing
                                    Just input -> appendChild o (Just input)

getConstInput :: Document -> PureFOLTerm -> IORef PolyadicModel -> IO (Maybe Element)
getConstInput w t mdl = case addConstant t mdl (Term 0) of
                            Nothing -> return Nothing
                            Just _ -> do
                                 Just constLabel <- createElement w (Just "label")
                                 setInnerHTML constLabel (Just $ show t ++ ": ")
                                 (constInput,parseWarn) <- parsingInput w parseInt constUpdater
                                 setAttribute constInput "name" (show t)
                                 setAttribute constInput "rows" "1"
                                 setValue (castToHTMLTextAreaElement constInput) (Just "0")
                                 appendChild constLabel (Just constInput)
                                 appendChild constLabel (Just parseWarn)
                                 return $ Just constLabel
    where constUpdater ext = case addConstant t mdl ext of
                                 Just io -> liftIO io
                                 Nothing -> return ()

getPropInput :: Document -> PureFOLForm -> IORef PolyadicModel -> IO (Maybe Element)
getPropInput w f mdl = case addProposition f mdl False of
                            Nothing -> return Nothing
                            Just _ -> do
                                 Just propLabel <- createElement w (Just "label")
                                 setInnerHTML propLabel (Just $ show f ++ ": ")
                                 [Just propSelect, Just pt ,Just pf] <- mapM (createElement w . Just) ["select","option","option"]
                                 setInnerHTML pt (Just "True")
                                 setInnerHTML pf (Just "False")
                                 setAttribute pf "selected" "selected"
                                 mapM (appendChild propSelect) [Just pt,Just pf]
                                 setAttribute propSelect "name" (show f)
                                 setAttribute propSelect "rows" "1"
                                 whenChange <- newListener propUpdater
                                 whenInit <- newListener propUpdater
                                 addListener propSelect initialize whenInit False
                                 addListener propSelect change whenChange False
                                 appendChild propLabel (Just propSelect)
                                 return $ Just propLabel
    where propUpdater :: EventM HTMLInputElement Event ()
          propUpdater = do 
             Just t <- target
             sval <- getValue t 
             case addProposition f mdl (if sval == Just "True" then True else False) of 
                Just io -> liftIO io
                Nothing -> return ()

getRelationInput :: Document -> PureFOLForm -> IORef PolyadicModel -> IO (Maybe Element)
getRelationInput w f mdl = case addRelation f mdl [] of
                             Nothing -> return Nothing
                             Just io -> do 
                                 mlen <- io
                                 case mlen of 
                                      Nothing -> return Nothing
                                      Just n -> do
                                         Just relationLabel <- createElement w (Just "label")
                                         setInnerHTML relationLabel (Just $ show (blankTerms f) ++ ": ")
                                         (relationInput,parseWarn) <- parsingInput w (ntuples n) relationUpdater
                                         setAttribute relationInput "name" (show (blankTerms f))
                                         setAttribute relationInput "rows" "1"
                                         setAttribute relationInput "class" "relationInput"
                                         appendChild relationLabel (Just relationInput)
                                         appendChild relationLabel (Just parseWarn)
                                         return $ Just relationLabel
    where relationUpdater ext = case addRelation f mdl ext of
                                     Just io -> liftIO io >> return ()
                                     Nothing -> return ()

getFunctionInput :: Document -> PureFOLTerm -> IORef PolyadicModel -> IO (Maybe Element)
getFunctionInput w f mdl = case addFunction f mdl [] of
                             Nothing -> return Nothing
                             Just io -> do 
                                 mlen <- io
                                 case mlen of 
                                      Nothing -> return Nothing
                                      Just n -> do
                                         Just functionLabel <- createElement w (Just "label")
                                         setInnerHTML functionLabel (Just $ show (blankFuncTerms f) ++ ": ")
                                         (functionInput,parseWarn) <- parsingInput w (nfunctuples (n + 1)) functionUpdater
                                         setAttribute functionInput "name" (show (blankFuncTerms f))
                                         setAttribute functionInput "rows" "1"
                                         setAttribute functionInput "class" "functionInput"
                                         appendChild functionLabel (Just functionInput)
                                         appendChild functionLabel (Just parseWarn)
                                         return $ Just functionLabel
    where functionUpdater ext = case addFunction f mdl ext of
                                     Just io -> liftIO io >> return ()
                                     Nothing -> return ()


addRelation :: PureFOLForm -> IORef PolyadicModel -> [[Thing]] -> Maybe (IO (Maybe Int))
addRelation f mdl extension = withArity onRel (AZero :: Arity (Term Int) (Form Bool) (Form Bool)) f
    where _predIdx' :: Typeable ret =>  Prism' (PureLanguageFOL ret) (Int, Arity (Term Int) (Form Bool) ret)
          _predIdx' = _predIdx
          onRel :: Arity (Term Int) (Form Bool) ret -> PureLanguageFOL ret -> IO (Maybe Int)
          onRel _ f@(Fx _) = case preview _predIdx' f of 
                 Nothing -> return Nothing
                 Just (idx,a) -> do
                     modifyIORef mdl $ \m -> m
                        { relation = \a' n -> if n == idx && show a == show a'
                            then toRelation extension a'
                            else relation m a' n
                        }
                     return $ Just (arityInt a)

addFunction :: PureFOLTerm-> IORef PolyadicModel -> [[Thing]] -> Maybe (IO (Maybe Int))
addFunction f mdl extension = withArity onFunc (AZero :: Arity (Term Int) (Term Int) (Term Int)) f
    where _funcIdx' :: Typeable ret =>  Prism' (PureLanguageFOL ret) (Int, Arity (Term Int) (Term Int) ret)
          _funcIdx' = _funcIdx
          onFunc :: Arity (Term Int) (Term Int) ret -> PureLanguageFOL ret -> IO (Maybe Int)
          onFunc _ f@(Fx _) = case preview _funcIdx' f of 
                 Nothing -> return Nothing
                 Just (idx,a) -> do
                     modifyIORef mdl $ \m -> m
                        { function = \a' n -> if n == idx && show a == show a'
                            then toFunction (toMap (arityInt a) extension) a'
                            else function m a' n
                        }
                     return $ Just (arityInt a)
          toMap n = fromList . map (splitTup n) 
          splitTup n tup = (take n tup, head (Prelude.drop n tup))

addConstant :: PureFOLTerm-> IORef PolyadicModel -> Thing -> Maybe (IO ())
addConstant t mdl extension = case preview _constIdx t of
                                  Nothing -> Nothing
                                  Just idx -> Just $ modifyIORef mdl $ \m -> m
                                        { monadicPart = (monadicPart m) 
                                            { name = \n -> if n == idx then extension else name (monadicPart m) n }
                                        }
                                    
addProposition :: PureFOLForm -> IORef PolyadicModel -> Bool -> Maybe (IO ())
addProposition t mdl extension = case preview _propIndex t of
                                  Nothing -> Nothing
                                  Just idx -> Just $ modifyIORef mdl $ \m -> m
                                        { monadicPart = (monadicPart m) 
                                            { proposition = \n -> if n == idx then Form extension else proposition (monadicPart m) n }
                                        }

initModel :: IO (IORef PolyadicModel)
initModel = newIORef (PolyadicModel 
                     { relation = \a _ -> toRelation mempty a
                     , function = \a _ -> toFunction mempty a
                     , monadicPart = MonadicModel
                        { domain = [Term 0]
                        , property = \_ _ -> Form False
                        , name = \_ -> Term 0
                        , proposition = \_ -> Form False
                        }
                     })

parsingInput :: Document -> Parsec String () a -> (forall e. IsEvent e => a -> EventM HTMLInputElement e ()) -> IO (Element,Element)
parsingInput w parser event = do Just theInput <- createElement w (Just "textarea")
                                 Just theWarning <- createElement w (Just "span")
                                 whenKey <- newListener (doesParse theWarning)
                                 whenInit <- newListener (doesParse theWarning)
                                 addListener theInput initialize whenInit False
                                 addListener theInput keyUp whenKey False
                                 return (theInput,theWarning)
    where doesParse :: IsEvent e => Element -> EventM HTMLInputElement e ()
          doesParse warn = do 
             Just t <- target 
             Just ival <- getValue t
             case parse (parser <* eof) "" ival of
                 Left e -> liftIO $ setInnerHTML warn (Just "⚠") --XXX: Consider a tooltip here.
                 Right x -> (liftIO $ setInnerHTML warn (Just "")) >> event x

extractField :: Element -> IO (String, String)
extractField field = do inputs <- getListOfElementsByTag field "textarea"
                        selects <- getListOfElementsByTag field "select"
                        case (inputs,selects) of
                            ([Just input],_) -> do 
                              Just fieldName <- getAttribute input "name"
                              Just ival <- getValue (castToHTMLTextAreaElement input)
                              return (fieldName, ival) 
                            (_,[Just select]) -> do 
                              Just fieldName <- getAttribute select "name"
                              Just sval <- S.getValue (castToHTMLSelectElement select)
                              return (fieldName, sval)

makeGivens :: Map String String -> [(String,String)]
makeGivens opts = case M.lookup "content" opts of
                      Nothing -> []
                      Just t -> map (clean . break (== ':')) . lines $ t
    where clean (x,y) = (x, tail y)

--XXX: a lot of unsafe pattern matching and catMaybe here...
validateModel :: [Element] -> IO (Either String ())
validateModel fields = do inputs <- catMaybes . concat <$> mapM (\f -> getListOfElementsByTag f "textarea") fields
                          names <- mapM (\i -> getAttribute i "name") inputs
                          let namedInputs = zip inputs names
                              [domain] = map fst . filter (\(x,y) -> y == Just "Domain") $ namedInputs
                              namedSymbols = filter (\(x,y) -> y /= Just "Domain") $ namedInputs
                          Just domainString <- getValue (castToHTMLTextAreaElement domain)
                          case parse (parseInt `sepEndBy1` (spaces *> char ',' <* spaces) <* eof) "" domainString of
                              Left e -> return $ Left $ "Couldn't read domain specification: " ++ show e
                              Right things -> do
                                  if null things 
                                      then return $ Left "The domain cannot be empty"
                                      else do
                                          namedClassedSymbols <- mapM (\(e,n) -> (,,) <$> pure e <*> pure n <*> getAttribute e "class") namedSymbols
                                          let funcInputs = filter (\(e,n,c) -> c == Just "functionInput") $ namedClassedSymbols
                                              relInputs = filter (\(e,n,c) -> c == Just "relationInput") $ namedClassedSymbols
                                              getText = getValue . castToHTMLTextAreaElement
                                          funcStrings <- mapM (\(e,n,_) -> (,,) <$> getText e <*> getBlanks n <*> pure n) funcInputs
                                          relStrings  <- mapM (\(e,n,_) -> (,,) <$> getText e <*> getBlanks n <*> pure n) relInputs
                                          allStrings <- mapM getText inputs
                                          let allAllegedThings = zip (map (parse extractor "" . clean) (catMaybes allStrings)) names
                                              funcChecks = map (validateFunc things) funcStrings
                                              relChecks = map (validateRel things) relStrings
                                              checks = filter isLeft $ funcChecks ++ relChecks
                                          case filter (isLeft . fst) allAllegedThings of
                                              (Left err,Just n):_ -> return $ Left $ "Couldn't read specification for " ++ n ++ ": " ++ show err
                                              [] -> case filter (\(Right ext,_) -> not (ext `subset` things)) allAllegedThings of
                                                   (_,Just n):_ -> return $ Left $ "The extension of " ++ n ++ " is not contained in the domain."
                                                   [] -> if null checks then return $ Right () 
                                                                        else return . head . filter isLeft $ checks

                       
    where clean (',':xs) = ' ':clean xs
          clean ('[':xs) = ' ':clean xs
          clean (']':xs) = ' ':clean xs
          clean ('(':xs) = ' ':clean xs
          clean (')':xs) = ' ':clean xs
          clean ('<':xs) = ' ':clean xs
          clean ('>':xs) = ' ':clean xs
          clean (';':xs) = ' ':clean xs
          clean (y:ys) = y:clean ys
          clean [] = []
          getBlanks (Just n) = pure . length . filter (== '_') $ n
          getBlanks Nothing = Prelude.error "issue with getting the number of blanks in a name"
          extractor = spaces *> (parseInt `sepEndBy` spaces) <* spaces
          subset (x:xs) y = x `elem` y && xs `subset` y
          subset [] y = True
          validateRel domain (_,_,Nothing) = Left $ "Couldn't get one of the relation specifications."
          validateRel domain (Nothing,_,Just n) = Left $ "Couldn't get the relation specification for " ++ n ++ "."
          validateRel domain (Just relstring,arity,Just n) = case parse (ntuples arity) "" relstring of
                Left e -> Left $ "Couldn't read the relation specification for " ++ n ++ ": " ++ show e
                Right _ -> Right ()
          validateFunc domain (_,_,Nothing) = Left $ "Couldn't get one of the function specifications."
          validateFunc domain (Nothing,_,Just n) = Left $ "Couldn't get the function specification for " ++ n ++" ."
          validateFunc domain (Just funcstring,arity, Just n) = case parse (nfunctuples (arity + 1)) "" funcstring of
                Left e -> Left $ "Couldn't read the function specification for " ++ n ++ ": " ++ show e
                Right tups | null tups -> Left $ "the function " ++ n ++ " is unspecified"
                           | not . properList . map init $ tups -> Left $ "the function " ++ n ++ " has more than one value specified for some input"
                           | let fdom = map init tups in sort fdom == sort (length (head fdom) `tuplesOn` domain) -> Right ()
                           | otherwise -> Left $ "the function " ++ n ++ " does not have a value specified for some input"
          properList [] = True
          properList (x:xs) = not (x `elem` xs) && properList xs
          tuplesOn 0 dom = []
          tuplesOn 1 dom = map (\x->[x]) dom
          tuplesOn n dom = do x <- dom
                              tup <- tuplesOn (n - 1) dom
                              return $ x:tup

setField :: Document -> [Element] -> (String,String) -> IO ()
setField w fields (name,val) = do inputs <- concat <$> mapM (\f -> getListOfElementsByTag f "textarea") fields
                                  selects <- concat <$> mapM (\f -> getListOfElementsByTag f "select") fields
                                  names <- mapM (\(Just i) -> getAttribute i "name") (inputs ++ selects)
                                  let fs = map fst . filter (\f -> snd f == Just name) $ zip (inputs ++ selects) names
                                  case fs of
                                   [Just f] -> do tn <- getTagName f
                                                  case tn of 
                                                    Just "INPUT" -> setValue (castToHTMLTextAreaElement f) (Just val)
                                                    Just "SELECT" -> S.setValue (castToHTMLSelectElement f) (Just val)
                                                    Just s -> print $ "unrecognized tag:" ++ s
                                                    Nothing -> print "no tagname"
                                                  Just init <- createEvent w "Event"
                                                  initEvent init "initialize" True True
                                                  dispatchEvent f (Just init)
                                                  return ()
                                   _ -> print $ "missing or duplicated field " ++ name ++ "in countermodel spec"

blankTerms :: PureFOLForm -> PureFOLForm
blankTerms f = set termsOf (foVar "_") f

blankFuncTerms :: PureFOLTerm -> PureFOLTerm
blankFuncTerms f = set termsOf (foVar "_") f

parseInt :: Parsec String () Thing
parseInt = Term . read <$> many1 digit

wrappedIn :: Char -> Char -> Parsec String () a -> Parsec String () a
wrappedIn l r p = char l *> spaces *> p <* spaces <* char r

tuple :: Parsec String () [Thing]
tuple = wrappedIn '[' ']' p <|> wrappedIn '<' '>' p <|> wrappedIn '(' ')' p <|> ((\x->[x]) <$> parseInt)
    where p = parseInt `sepBy` (spaces *> char ',' <* spaces)

functuple :: Parsec String () [Thing]
functuple = wrappedIn '[' ']' p <|> wrappedIn '<' '>' p <|> wrappedIn '(' ')' p
    where p = do args <- parseInt `sepBy` (spaces *> char ',' <* spaces)
                 val <- spaces *> char ';' *> spaces *> parseInt
                 return (args ++ [val])

ntuple :: Int -> Parsec String () [Thing]
ntuple n = do t <- tuple; if length t == n then return t else fail ("This extension should be made only of " ++ show n ++ "-tuples")

nfunctuple :: Int -> Parsec String () [Thing]
nfunctuple n = do t <- functuple; if length t == n then return t else fail ("This extension should be made only of " ++ show n ++ "-tuples")

ntuples :: Int -> Parsec String () [[Thing]]
ntuples n = ntuple n `sepEndBy` (spaces *> char ',' <* spaces) <* eof

nfunctuples :: Int -> Parsec String () [[Thing]]
nfunctuples n = nfunctuple n `sepEndBy` (spaces *> char ',' <* spaces) <* eof
