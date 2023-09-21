#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "ghc.withPackages (ps: [ ps.hiedb ps.temporary ])" -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/8cad3dbe48029cb9def5cdb2409a6c80d3acfe2e.tar.gz

import HieDb
import Data.IORef (newIORef)
import Data.List (elemIndex)
import Data.Maybe (fromJust)
import Algebra.Graph.AdjacencyMap
import qualified Algebra.Graph.Acyclic.AdjacencyMap as Acyclic
import qualified Algebra.Graph.NonEmpty.AdjacencyMap as NonEmpty
import qualified Data.Set as Set
import Control.Monad (forM_)
import System.IO (hPutStrLn, withFile, IOMode(WriteMode))
import System.IO.Temp (writeSystemTempFile)

-- settings for input & cache files
hiedir = ".hiefiles"
dbFile = "db.sqlite"
-- settings for graphviz color scheme
colorScheme="pastel19"

-- Find the cross-module function dependency cycles in a haskell project,
-- and write them to .dot files

main = withHieDb dbFile $ \db -> do
    -- Get the definition-dependency graph
    g <- getOrCreateGraph db
    -- Get Strongly Connected Components,
    -- i.e. clumps of mutually recursive defintions
    let clumps = Acyclic.scc g
    -- Keep only SCCs that cross modules
    let sccs = Acyclic.vertexSet . Acyclic.induce (not . allInSameModule . Set.toList . NonEmpty.vertexSet) $ clumps
    -- Print out analysis
    putStrLn $ "There are " ++ (show . Set.size) sccs ++ " cross-module SCCs in the code."
    forM_ ([1..] `zip` Set.toList sccs) $ \(n,scc) ->
        withFile (concat ["scc",show n,".dot"]) WriteMode $ \h -> do
            let vertsInSCC = NonEmpty.vertexSet scc
            let edgesInSCC = NonEmpty.edgeSet scc
            let modsInSCC = Set.toList . Set.map (\(mod,_,_,_,_,_,_) -> mod) $ vertsInSCC
            putStrLn $ "The modules involved in SCC #"++ show n++" are " ++ show modsInSCC
            hPutStrLn h "digraph {"
            hPutStrLn h $ "node[style=filled,colorscheme=" ++ colorScheme ++ "];"
            forM_ vertsInSCC $ \v -> do
                hPutStrLn h $ toDotNode modsInSCC v
            forM_ edgesInSCC $ \(v1,v2) -> do
                hPutStrLn h $ toDotLabel v1 ++ " -> " ++ toDotLabel v2
            hPutStrLn h "}"

-- Are all the vertices in a list from the same module?
allInSameModule :: [Vertex] -> Bool
allInSameModule [] = True
allInSameModule ((mod,_,_,_,_,_,_):xs) = all (\(mod',_,_,_,_,_,_) -> mod' == mod) xs

-- Pretty-print vertex to graphviz DOT label
toDotLabel :: Vertex -> String
toDotLabel (modul,_,ident,sl,_,el,_) = show . concat $
    [modul, ".", tail ident , "\n@[", show sl, ",", show el++"]"]

-- Pretty-print vertex to graphviz DOT node (incl. formatting)
toDotNode :: [String] -> Vertex -> String
toDotNode mods v@(modul,_,ident,_,_,_,_) = let
    -- Shape based on identifier type (type, constructor, function)
    shape = case head ident of
        't' -> "rect" -- types
        'c' -> "octagon" -- data constructors
        'v' -> "ellipse" -- functions
        _ -> "star" -- unknown
    -- Color based on module name
    color = show . (+1) . fromJust $ elemIndex modul mods
    formatting = concat $ ["[shape=", shape,",fillcolor=",color,"]"]
    in toDotLabel v ++ formatting

-- Load HieDb from file (creating file if does not exist)
getOrCreateGraph :: HieDb -> IO (AdjacencyMap Vertex) 
getOrCreateGraph db = do
    g0 <- getGraph db
    if g0 /= empty then return g0
    else do
        initConn db
        hiefiles <- getHieFilesIn hiedir
        print hiefiles
        ncr <- newIORef =<< makeNc
        runDbM ncr $ addRefsFrom db `mapM_` hiefiles
        getGraph db
