{-# LANGUAGE LambdaCase #-}
{-# OPTIONS -Wno-unused-matches -Wno-unused-local-binds -Wno-unused-top-binds -Wno-unused-imports #-}
module Main(main) where

import Control.Monad (when)
import Data.Bool (bool)
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.List (intercalate, isPrefixOf)
import Data.Map (Map)
import Data.Maybe (isJust)
import Data.Semigroup ((<>), Semigroup)
import Data.Set (Set)
import Data.Version (showVersion)
import Data.Void (Void)
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Printf (printf)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Debug.Trace
import System.Environment (getArgs)
import System.Exit (exitSuccess)
import qualified Paths_simformat as Paths

type Parser = Parsec Void String

-- Sorting

-- The key type is carefully chosen so `Map.toList` puts the qualified imports at the bottom,
-- and then sorts by module name.
newtype SortedImportStmts = SortedImportStmts
  { unSortedImportStmts :: Map (Bool, String, Maybe String) SortedImportList
  }
  deriving Show

-- High level elements

data ImportStmt = ImportStmt
  { importStmtQualified  :: Bool
  , importStmtModuleName :: String
  , importStmtAlias      :: Maybe String
  , importStmtImportList :: SortedImportList
  } deriving Show

setDiff :: Ord a => Set a -> Set a -> Maybe (Set a)
setDiff x y = Just $ Set.difference x y

-- Order chosen here so that sorting them will put the hiding clauses
-- first, then partial imports, then open imports.
data SortedImportList
  = HidingImport  (Map GroupKeyType (Set String))
  | PartialImport (Map GroupKeyType (Set String))
  | OpenImport
  deriving (Show,Ord,Eq)

instance Semigroup SortedImportList where
  OpenImport      <> _               = OpenImport
  _               <> OpenImport      = OpenImport
  HidingImport  a <> HidingImport b  = HidingImport  (Map.intersectionWith Set.intersection a b)
  PartialImport a <> PartialImport b = PartialImport (Map.unionWith Set.union a b)
  HidingImport  a <> PartialImport b = HidingImport  (Map.differenceWith setDiff a b)
  PartialImport b <> HidingImport a  = HidingImport  (Map.differenceWith setDiff a b)

data GroupKeyType
  = ConstructorTypeKey String
  | NoGroupTypeKey
  | ConstructorKey String
  | NoGroupKey
  deriving (Show,Ord,Eq)

data ImportEntry
  = ImportEntryTypeGroup ImportGroup
  | ImportEntryTypeAtom String
  | ImportEntryGroup ImportGroup
  | ImportEntryAtom String
  deriving (Show,Ord,Eq)

-- | ImportGroup: something like (Monoid(mempty,mappend)) in an import
--   line.
data ImportGroup = ImportGroup
  { _importGroupName :: String
  , _importGroupList :: Set String
  }
  deriving (Show,Ord,Eq)

-- $setup
-- >>> import Data.Maybe (fromJust)

-- General parsing

comma :: Parser String
comma = string ","

padded :: Parser a -> Parser a
padded = between space space

commaSep :: Parser a -> Parser [a]
commaSep a = sepBy (padded a) (padded comma)

parens :: Parser a -> Parser a
parens = between (ptoken "(") (ptoken ")")

ptoken :: String -> Parser String
ptoken = padded . string

-- Basic elements

-- |
-- >>> parseMaybe (parseList symbol) "( hi, bye )"
-- Just ["hi","bye"]
parseList :: Parser a -> Parser [a]
parseList p = parens $ commaSep p

-- |
-- >>> parseMaybe operator "(<$>)"
-- Just "(<$>)"
operator :: Parser String
operator = concat <$> sequence [ptoken "(", some $ oneOf symbolChars, ptoken ")"]

symbolChars :: String
symbolChars = "!#$%&*+./<=>?@^|-~:\\"

-- |
-- >>> parseMaybe symbol "_Identity"
-- Just "_Identity"
-- >>> parseMaybe symbol "(<>)"
-- Just "(<>)"
symbol :: Parser String
symbol = padded $ operator <|> some (alphaNumChar <|> oneOf ("._'" :: String))

parseImportBlock :: Parser SortedImportStmts
parseImportBlock = toSortedImportStmts <$> some parseImportStmt

-- |
-- >>> parseMaybe parseImportStmt "import qualified Data.Map as Map"
-- Just (ImportStmt {importStmtQualified = True, importStmtModuleName = "Data.Map", importStmtAlias = Just "Map", importStmtImportList = OpenImport})
-- >>> parseMaybe parseImportStmt "import Data.Maybe (catMaybes, fromMaybe, isJust)"
-- Just (ImportStmt {importStmtQualified = False, importStmtModuleName = "Data.Maybe", importStmtAlias = Nothing, importStmtImportList = PartialImport (fromList [(Right (),fromList ["catMaybes","fromMaybe","isJust"])])})
-- >>> parseMaybe parseImportStmt "import Data.Monoid (Monoid(mempty, mappend), (<>))"
-- Just (ImportStmt {importStmtQualified = False, importStmtModuleName = "Data.Monoid", importStmtAlias = Nothing, importStmtImportList = PartialImport (fromList [(Left "Monoid",fromList ["mappend","mempty"]),(Right (),fromList ["(<>)"])])})
-- >>> parseMaybe parseImportStmt "import Data.Monoid (Monoid(..), (<>))"
-- Just (ImportStmt {importStmtQualified = False, importStmtModuleName = "Data.Monoid", importStmtAlias = Nothing, importStmtImportList = PartialImport (fromList [(Left "Monoid",fromList [".."]),(Right (),fromList ["(<>)"])])})
-- >>> parseMaybe parseImportStmt "import OrphanInstances ()"
-- Just (ImportStmt {importStmtQualified = False, importStmtModuleName = "OrphanInstances", importStmtAlias = Nothing, importStmtImportList = PartialImport (fromList [])})
-- >>> parseMaybe parseImportStmt "import Foo hiding (Bar, (+))"
-- Just (ImportStmt {importStmtQualified = False, importStmtModuleName = "Foo", importStmtAlias = Nothing, importStmtImportList = HidingImport (fromList [(Right (),fromList ["(+)","Bar"])])})
parseImportStmt :: Parser ImportStmt
parseImportStmt = ImportStmt
              <$> ( ptoken "import"
                 *> (fmap isJust . optional $ ptoken "qualified")
                  )
              <*> symbol
              <*> optional (ptoken "as" *> symbol)
              <*> (mkSortedImportList =<<
                   (,) <$> optional (parseList parseImportEntry)
                       <*> optional (string "hiding" >> parseList parseImportEntry))
  where
    mkSortedImportList :: (Maybe [ImportEntry], Maybe [ImportEntry]) -> Parser SortedImportList
    mkSortedImportList (Just x, Nothing) = pure $ PartialImport $ buildImportList x
    mkSortedImportList (Nothing,Just x)  = pure $ HidingImport $ buildImportList  x
    mkSortedImportList (Nothing,Nothing) = pure OpenImport
    mkSortedImportList (Just _, Just _) = fail "can't specify both a hiding clause and an import clause"

    buildImportList :: [ImportEntry] -> Map.Map GroupKeyType (Set String)
    buildImportList = Map.fromListWith Set.union . map extractKey

    extractKey :: ImportEntry -> (GroupKeyType, Set String)
    extractKey (ImportEntryTypeGroup (ImportGroup k s)) = (ConstructorTypeKey k, s)
    extractKey (ImportEntryGroup (ImportGroup k s)) = (ConstructorKey k, s)
    extractKey (ImportEntryTypeAtom s)                  = (NoGroupTypeKey, Set.singleton s)
    extractKey (ImportEntryAtom s)                      = (NoGroupKey, Set.singleton s)

parseImportEntry :: Parser ImportEntry
parseImportEntry = do
  name <- symbol
  if name == "type"
  then do
    name' <- symbol
    ImportEntryTypeGroup <$> parseImportGroup name' <|> pure (ImportEntryTypeAtom name')
  else do
    ImportEntryGroup <$> parseImportGroup name <|> pure (ImportEntryAtom name)

parseImportGroup :: String -> Parser ImportGroup
parseImportGroup name = ImportGroup name . Set.fromList
                    <$> parseList symbol

toSortedImportStmts :: [ImportStmt] -> SortedImportStmts
toSortedImportStmts = SortedImportStmts . fmap simplify . Map.fromListWith (<>) . map extractKey
  where
    extractKey ImportStmt{..} =
      ((importStmtQualified, importStmtModuleName, importStmtAlias)
      ,importStmtImportList)

    simplify :: SortedImportList -> SortedImportList
    simplify (HidingImport x)
      -- an empty hiding list is just an open import
      | all Set.null (Map.elems x) = OpenImport
      | otherwise = HidingImport x
    simplify x = x

fromSortedImportStmts :: SortedImportStmts -> [ImportStmt]
fromSortedImportStmts = map (uncurry go) . Map.toList . unSortedImportStmts
  where
    go :: (Bool, String, Maybe String) -> SortedImportList -> ImportStmt
    go (qualified, moduleName, alias) sortedImportList = ImportStmt
      { importStmtQualified  = qualified
      , importStmtModuleName = moduleName
      , importStmtAlias      = alias
      , importStmtImportList = sortedImportList
      }

-- Rendering

tooLong :: String -> Bool
tooLong line = length line > 100

-- Either a string which fits on one line, or a list of lines if needed.
renderList :: String -> (a -> String) -> [a] -> Either String [String]
renderList indent renderItem xs0 | null xs0        = Left "()"
                                 | tooLong oneLine = Right multiLine
                                 | otherwise       = Left oneLine
  where
    oneLine = printf "(%s)" . intercalate ", " . map renderItem $ xs0
    multiLine = go (indent <> "( ") True xs0
      where
        -- 'acc' contains the line so far, the Bool is True if that's only punctuation
        go _   True  []     = [indent <> ")"]
        go acc False []     = [acc, indent <> ")"]
        go acc True  (x:xs) = go (acc <> renderItem x) False xs
        go acc False (x:xs) | tooLong acc' = acc : go (indent <> ", " <> renderedItem) False xs
                            | otherwise    = go acc' False xs
          where
            renderedItem = renderItem x
            acc' = acc <> ", " <> renderedItem

-- |
-- >>> let test = putStr . unlines . map ('|':) . lines . intercalate "\n" . map renderImportStmt . fromSortedImportStmts . fromJust . parseMaybe parseImportBlock
--
-- Short import lists are kept on a single line:
--
-- >>> test "import qualified Data.Map as Map"
-- |import qualified Data.Map as Map
-- >>> test "import Data.Maybe (catMaybes, fromMaybe, isJust)"
-- |import Data.Maybe (catMaybes, fromMaybe, isJust)
-- >>> test "import OrphanInstances ()"
-- |import OrphanInstances ()
--
-- Longer import lists are split onto multiple lines, keeping groups together:
--
-- >>> test "import FooBar (baz17, baz18, baz01, baz02, baz03, baz04, baz05, baz06, baz07, baz08, baz09, baz10, baz11, baz12, baz13, baz14, baz15, baz16, Foo(foo7, foo8, foo9, foo1, foo2, foo3, foo4, foo5, foo6), Bar(bar7, bar8, bar9, bar1, bar2, bar3, bar4, bar5, bar6), baz19, baz20)"
-- |import FooBar
-- |  ( Bar(bar1, bar2, bar3, bar4, bar5, bar6, bar7, bar8, bar9)
-- |  , Foo(foo1, foo2, foo3, foo4, foo5, foo6, foo7, foo8, foo9), baz01, baz02, baz03, baz04, baz05
-- |  , baz06, baz07, baz08, baz09, baz10, baz11, baz12, baz13, baz14, baz15, baz16, baz17, baz18, baz19
-- |  , baz20
-- |  )
-- >>> test "import FooBar (quux17, quux18, quux01, quux02, quux03, quux04, quux05, quux06, quux07, quux08, quux09, quux10, quux11, quux12, quux13, quux14, quux15, quux16, Foo(foo7, foo8, foo9, foo1, foo2, foo3, foo4, foo5, foo6), Baz(baz01, baz02, baz03, baz04, baz05, baz06, baz07, baz010, baz011, baz012, baz013, baz014, baz015, baz016, baz017, baz020), Bar(bar7, bar8, bar9, bar1, bar2, bar3, bar4, bar5, bar6), quux19, quux20)"
-- |import FooBar
-- |  ( Bar(bar1, bar2, bar3, bar4, bar5, bar6, bar7, bar8, bar9)
-- |  , Baz
-- |    ( baz01, baz010, baz011, baz012, baz013, baz014, baz015, baz016, baz017, baz02, baz020, baz03
-- |    , baz04, baz05, baz06, baz07
-- |    )
-- |  , Foo(foo1, foo2, foo3, foo4, foo5, foo6, foo7, foo8, foo9), quux01, quux02, quux03, quux04
-- |  , quux05, quux06, quux07, quux08, quux09, quux10, quux11, quux12, quux13, quux14, quux15, quux16
-- |  , quux17, quux18, quux19, quux20
-- |  )
--
-- Multiple imports are merged and sorted:
--
-- >>> test "import A (A(unA, runA))\nimport qualified Data.Map as Map\nimport A (A(unA, MkA))\nimport Data.Map (lookup)"
-- |import A (A(MkA, runA, unA))
-- |import Data.Map (lookup)
-- |import qualified Data.Map as Map
--
-- Empty hiding lists should be elided
-- >>> test "import Foo hiding (Bar)\nimport Baz\nimport Foo hiding (quux)"
-- |import Baz
-- |import Foo
--
-- Hiding wins over imports
-- >>> test "import Foo hiding (Bar)\nimport Foo(baz)\n"
-- |import Foo hiding (Bar)
--
-- Hiding imports go first, then normal imports, then qualified
-- >>> test "import qualified Foo\nimport Bar hiding(baz)\nimport Quux"
-- |import Bar hiding (baz)
-- |import Quux
-- |import qualified Foo

renderImportStmt :: ImportStmt -> String
renderImportStmt ImportStmt {..} = "import"
                                <> bool "" " qualified" importStmtQualified
                                <> printf " %s" importStmtModuleName
                                <> maybe "" (printf " as %s") importStmtAlias
                                <> renderImportList importStmtImportList

renderImportStmts :: SortedImportStmts -> String
renderImportStmts = unlines . map renderImportStmt . fromSortedImportStmts

renderImportList :: SortedImportList -> String
renderImportList = \case
  OpenImport      -> ""
  HidingImport h  -> " hiding" <> renderImportEntries h
  PartialImport i -> renderImportEntries i

renderImportEntries :: Map.Map GroupKeyType (Set String) -> String
renderImportEntries =   either (' ':) (('\n':) . intercalate "\n")
                    . renderList "  " id
                    . concatMap chunkImportEntry
                    . Map.toAscList

chunkImportEntry :: (GroupKeyType, Set String) -> [String]
chunkImportEntry (NoGroupKey, s) = Set.toAscList s
chunkImportEntry (NoGroupTypeKey, s) = ("type " <>) <$> Set.toAscList s
chunkImportEntry (ConstructorKey importGroupName, importGroupList) =
  [importGroupName <> renderGroupList importGroupList]
chunkImportEntry (ConstructorTypeKey importGroupName, importGroupList) =
  ["type " <> importGroupName <> renderGroupList importGroupList]

renderGroupList :: Set String -> String
renderGroupList = either id (('\n':) . intercalate "\n")
                . renderList "    " id . Set.toAscList


type BlankLine = String
type Block = Either BlankLine String

maybeShowVersionAndExit :: IO ()
maybeShowVersionAndExit = do
  args <- getArgs
  when ("--version" `elem` args) $ do
    putStrLn $ "simformat " ++ showVersion Paths.version
    exitSuccess
  when ("--numeric-version" `elem` args) $ do
    putStrLn $ showVersion Paths.version
    exitSuccess

main :: IO ()
main = do
  maybeShowVersionAndExit
  (nonimports, importsAndAfter) <- break ("import " `isPrefixOf`) . lines <$> getContents
  traverse_ outputBlock $ reassemble nonimports $ untilNothing processBlock (chunkedInputs importsAndAfter)

  where
    detectBlankLine :: String -> Either BlankLine String
    detectBlankLine s | all isSpace s = Left s
                      | otherwise     = Right s

    -- we want to process each chunk of imports as its own little block
    chunkedInputs :: [String] -> [Block]
    chunkedInputs = (fmap.fmap) unlines . splitOn detectBlankLine

    processBlock :: Block -> Maybe (Either BlankLine SortedImportStmts)
    processBlock (Left  s) = pure (Left s)
    processBlock (Right s) = Right <$> parseMaybe parseImportBlock s

    reassemble :: [String]
               -> ([Either BlankLine SortedImportStmts], [Block])
               -> [Block]
    reassemble nonImports (chunkedImports, leftovers)
      = fmap Left nonImports
     <> (fmap.fmap) renderImportStmts chunkedImports
     <> leftovers

    outputBlock :: Block -> IO ()
    outputBlock (Left  s) = putStrLn s
    outputBlock (Right s) = putStr s

-- |divide the input into blocks while preserving the number of separators
-- >>> splitOn (==0) [
splitOn :: (a -> Either separator b) -> [a] -> [Either separator [b]]
splitOn _ [] = []
splitOn f (x:xs) = case f x of
  Left separator -> Left separator : splitOn f xs
  Right y        -> case splitOn f xs of
    Right ys : zs -> Right (y:ys) : zs
    zs            -> Right [y] : zs

untilNothing :: (a -> Maybe b) -> [a] -> ([b], [a])
untilNothing f = go []
  where
    go ys [] = (reverse ys, [])
    go ys (x:xs) =
      case f x of
        Nothing -> (reverse ys, x:xs)
        Just y  -> go (y:ys) xs
