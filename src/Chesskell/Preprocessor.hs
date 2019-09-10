{-# LANGUAGE TemplateHaskell #-}

module Chesskell.Preprocessor where

import Data.Maybe (fromJust)
import Prelude hiding (round)
import Data.List      (find, iterate)
import Data.Char
import qualified Data.Matrix as Matrix hiding (fromList) 
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map hiding (take, map, filter)
import Control.Lens
import Chesskell.ChessCommons
import Chesskell.PGNParser

data GameState = GameState
    { _arrangement :: Arrangement
    , _figToPosMap :: Map Figure [Position]
    , _enPassantOp :: Maybe Position
    } deriving (Show)

type ExtraCoord = Maybe (Either Int Int)
type Position = (Int, Int) 
type FigAndPos = (Figure, Position)

makeLenses ''GameState

calcTags :: [RawTag] -> Tags
calcTags rawTags = 
    let findTagValue name = tagValue <$> find (\t -> tagName t == name) rawTags
    in Tags 
        { event  = findTagValue "Event"
        , site   = findTagValue "Site"
        , date   = findTagValue "Date"
        , round  = findTagValue "Round"
        , white  = findTagValue "White"
        , black  = findTagValue "Black"
        , result = findTagValue "Result"
        }

calcI :: Y -> Int
calcI (Y digit) = 8 - digit + 1

calcJ :: X -> Int
calcJ (X letter) = (ord letter - ord 'a') + 1

calcExtraCoord :: RawExtraCoord -> ExtraCoord
calcExtraCoord Nothing          = Nothing
calcExtraCoord (Just (Left x))  = Just . Right $ calcJ x
calcExtraCoord (Just (Right y)) = Just . Left  $ calcI y

calcPosition :: RawPosition -> Position
calcPosition (x, y) = (calcI y, calcJ x)

getExtraCoordPred :: ExtraCoord -> Position -> Bool
getExtraCoordPred Nothing _            = True
getExtraCoordPred (Just (Left i)) pos  = i == pos^._1
getExtraCoordPred (Just (Right j)) pos = j == pos^._2

validToPosPawnPred :: Position -> Position -> Color -> GameState -> Bool
validToPosPawnPred (i, j) toPos@(ii, jj) color gameState
    | abs (ii - i) == 1 && j == jj && (gameState^.arrangement) Matrix.! toPos == Nothing                    = True
    | abs (ii - i) == 2 && i == colorCoord && j == jj && (gameState^.arrangement) Matrix.! toPos == Nothing = True
    | abs (ii - i) == 1 && abs (jj - j) == 1 && (gameState^.arrangement) Matrix.! toPos /= Nothing          = True
    | abs (ii - i) == 1 && abs (jj - j) == 1 && gameState^.enPassantOp == (Just toPos)                      = True
    | otherwise                                                                                             = False
    where colorCoord = if (color == White) then 7 else 2

getBetweenPosLine :: Position -> Position -> Bool -> [Position]
getBetweenPosLine (i, j) (ii, jj) straight
    | i == ii && straight = notDiagonal ((,) i) j jj
    | j == jj && straight = notDiagonal (\x -> (x, j)) i ii
    | otherwise = 
        let minI = min i ii
            maxI = max i ii
            minJ = min j jj
            maxJ = max j jj
            genList = [(x, y) | x <- [minI..maxI], y <- [minJ..maxJ], abs (x - i) == abs (y - j)]
            tailed = tail genList
            inited = init tailed
        in inited
    where notDiagonal commonApp bord1 bord2 = 
            let minBord = min bord1 bord2
                maxBord = max bord1 bord2
            in init $ tail [commonApp x | x <- [minBord..maxBord]]

betweenPosLineIsClean :: Position -> Position -> Bool -> Arrangement -> Bool
betweenPosLineIsClean fromPos toPos straight arrangement =
    let betweenPosLine = getBetweenPosLine fromPos toPos straight
    in all (\pos -> arrangement Matrix.! pos == Nothing) betweenPosLine

calcFromPos :: Figure -> ExtraCoord -> Position -> GameState -> Position
calcFromPos figure@(color, figureType) extraCoord toPos@(ii, jj) gameState =
    let candidates = (gameState^.figToPosMap) Map.! figure
        ecFiltered = filter extraCoordPred candidates
        filtered   = filter validToPosPred ecFiltered
    in head filtered
    where extraCoordPred = getExtraCoordPred extraCoord
          validToPosPred = case figureType of
            King   -> \_ -> True
            Knight -> \(i, j) ->
                let dist = (abs $ ii - i, abs $ jj - j)
                in dist == (1, 2) || dist == (2, 1)
            Pawn   -> \fromPos -> validToPosPawnPred fromPos toPos color gameState
            Queen  -> \fromPos@(i, j) -> (i == ii || j == jj || abs (i - ii) == abs (jj - j))
                && betweenPosLineIsClean fromPos toPos True (gameState^.arrangement)
            Rook -> \fromPos@(i, j) -> (i == ii || j == jj || abs (i - ii) == abs (jj - j))
                && betweenPosLineIsClean fromPos toPos True (gameState^.arrangement)    
            Bishop -> \fromPos@(i, j) -> abs (i - ii) == abs (jj - j)
                && betweenPosLineIsClean fromPos toPos False (gameState^.arrangement)

removeCaptured :: FigAndPos -> GameState -> GameState
removeCaptured (captured, capturedPos) gameState = 
    let updatedArgm     = arrangement %~ cleanCapturedPos $ gameState
        updatedCaptured = figToPosMap %~ updateCaptured $ updatedArgm
    in updatedCaptured
    where cleanCapturedPos = Matrix.setElem Nothing capturedPos
          updateCaptured   = Map.adjust (filter (/= capturedPos)) captured

setEnPassant :: Position -> GameState -> GameState
setEnPassant enPassantPos gameState = enPassantOp .~ (Just enPassantPos) $ gameState

removeEnPassant :: GameState -> GameState
removeEnPassant gameState = enPassantOp .~ Nothing $ gameState

getCaptureUpdate :: Figure -> Position -> Bool -> GameState -> GameState
getCaptureUpdate (color, _) toPos wasCapture gameState = if (wasCapture)
    then 
        let toPosFigure     = (gameState^.arrangement) Matrix.! toPos
            enPassantChange = \coord -> if (color == White) then coord + 1 else coord - 1
            capturedPos     = case toPosFigure of 
                (Just _) -> toPos
                _        -> _1 %~ enPassantChange $ toPos
            captured        = fromJust ((gameState^.arrangement) Matrix.! capturedPos)
        in removeCaptured (captured, capturedPos) gameState
    else gameState

getEnPassantUpdate :: FigAndPos -> Position -> GameState -> GameState
getEnPassantUpdate ((color, figureType), fromPos@(i, j)) toPos@(ii, jj) = 
    if (figureType == Pawn && i == (if (color == White) then 7 else 2) && abs (ii - i) == 2)
    then setEnPassant (if (color == White) then (ii + 1, jj) else (ii - 1, jj))
    else removeEnPassant

getPawnTurnUpdate :: FigAndPos -> Maybe FigureType -> GameState -> GameState
getPawnTurnUpdate (figure@(color, _), toPos) turnIntoType = case turnIntoType of
    (Just turnFigureType) -> updatePawnTurn (figure, toPos) (color, turnFigureType)
    Nothing               -> id

makeMoveBase :: FigAndPos -> Position -> GameState -> GameState
makeMoveBase (figure, fromPos) toPos gameState = 
    let updatedArgm  = arrangement %~ (fillToPos . cleanFromPos) $ gameState
        updatedState = figToPosMap %~ updateFigure $ updatedArgm
    in updatedState
    where cleanFromPos = Matrix.setElem Nothing fromPos
          fillToPos    = Matrix.setElem (Just figure) toPos
          updateFigure = Map.adjust ((toPos :) . filter (/= fromPos)) figure

updatePawnTurn :: FigAndPos -> Figure -> GameState -> GameState
updatePawnTurn (pawn, pawnPos) figure gameState =
    let updatedArgm   = arrangement %~ replaceFigure $ gameState
        updatedTurned = figToPosMap %~ (addFigurePos . removePawnPos) $ updatedArgm
    in updatedTurned
    where replaceFigure = Matrix.setElem (Just figure) pawnPos
          removePawnPos = Map.adjust (filter (/= pawnPos)) pawn
          addFigurePos  = Map.adjust (pawnPos :) figure

makeMoveCastling :: FigAndPos -> FigAndPos -> Position -> Position -> GameState -> GameState
makeMoveCastling (king, kingFromPos) (rook, rookFromPos) kingToPos rookToPos gameState = 
    let updatedArgm  = arrangement %~ (fillRookToPos . cleanRookFromPos . fillKingToPos . cleanKingFromPos) $ gameState
        updatedState = figToPosMap %~ (updateRook . updateKing) $ updatedArgm
    in updatedState
    where cleanKingFromPos = Matrix.setElem Nothing kingFromPos
          fillKingToPos    = Matrix.setElem (Just king) kingToPos 
          cleanRookFromPos = Matrix.setElem Nothing rookFromPos
          fillRookToPos    = Matrix.setElem (Just rook) rookToPos
          updateKing       = Map.adjust ((kingToPos :) . filter (/= kingFromPos)) king
          updateRook       = Map.adjust ((rookToPos :) . filter (/= rookFromPos)) rook

calcNextGameState :: RawMove -> Color -> GameState -> GameState
calcNextGameState (BaseRawMove figureType rawExtraCoord wasCapture rawPosition turnIntoType _ _) color gameState =
    let captureUpdate   = getCaptureUpdate figure toPos wasCapture
        enPassantUpdate = getEnPassantUpdate (figure, fromPos) toPos
        moveUpdate      = makeMoveBase (figure, fromPos) toPos
        pawnTurnUpdate  = getPawnTurnUpdate (figure, toPos) turnIntoType
    in (pawnTurnUpdate . moveUpdate . enPassantUpdate . captureUpdate) gameState
    where figure          = (color, figureType)
          extraCoord      = calcExtraCoord rawExtraCoord
          toPos@(ii, jj)  = calcPosition rawPosition
          fromPos@(i, j)  = calcFromPos figure extraCoord toPos gameState
calcNextGameState castling color gameState =
    makeMoveCastling (king, kingFromPos) (rook, rookFromPos) kingToPos rookToPos gameState
    where colorCoord  = if (color == White) then 8 else 1
          king        = (color, King)
          kingFromPos = (colorCoord, 5)
          rook        = (color, Rook)
          rookFromPos = case castling of 
            ShortCastling _ _ -> (colorCoord, 8)
            _                 -> (colorCoord, 1)
          kingToPos   = case castling of 
            ShortCastling _ _ -> (colorCoord, 7)
            _                 -> (colorCoord, 3)
          rookToPos   = case castling of 
            ShortCastling _ _ -> (colorCoord, 6)
            _                 -> (colorCoord, 4)

calcArrangementsHelper :: [RawMove] -> [Arrangement] -> Color -> GameState -> [Arrangement]
calcArrangementsHelper [] argms _ gameState             = argms ++ [gameState^.arrangement]
calcArrangementsHelper (rm : rms) argms color gameState = 
    let newArgms      = argms ++ [gameState^.arrangement]
        nextColor     = oppositeColor color
        nextGameState = calcNextGameState rm color gameState
    in calcArrangementsHelper rms newArgms nextColor nextGameState

initialArrangement :: Arrangement
initialArrangement = Matrix.fromLists $
       [toBlack <$> mainFigureRow]
    ++ [toBlack <$> pawnRow]
    ++ replicate (chessBoardLength - 4) emptyRaw
    ++ [toWhite <$> pawnRow]
    ++ [toWhite <$> mainFigureRow]
    where
        mainFigureRow = [Rook, Knight, Bishop, Queen, King, Bishop, Knight, Rook]
        pawnRow       = replicate chessBoardLength Pawn
        emptyRaw      = replicate chessBoardLength Nothing
        toBlack       = Just . ((,) Black)
        toWhite       = Just . ((,) White)

initialFigToPosMap :: Map Figure [Position]
initialFigToPosMap = Map.fromList
    [ ((White, King)  , [(8, 5)])
    , ((White, Queen) , [(8, 4)])
    , ((White, Bishop), [(8, 3), (8, 6)])
    , ((White, Knight), [(8, 2), (8, 7)])
    , ((White, Rook)  , [(8, 1), (8, 8)])
    , ((White, Pawn)  , take 8 $ iterate (_2 %~ (+1)) (7, 1))
    , ((Black, King)  , [(1, 5)])
    , ((Black, Queen) , [(1, 4)])
    , ((Black, Bishop), [(1, 3), (1, 6)])
    , ((Black, Knight), [(1, 2), (1, 7)])
    , ((Black, Rook)  , [(1, 1), (1, 8)])
    , ((Black, Pawn)  , take 8 $ iterate (_2 %~ (+1)) (2, 1))
    ]

calcArrangements :: [RawMove] -> [Arrangement]
calcArrangements rawMoves = calcArrangementsHelper rawMoves [] White initialGameState
    where initialGameState = GameState 
            { _arrangement = initialArrangement
            , _figToPosMap = initialFigToPosMap
            , _enPassantOp = Nothing
            }

preprocessRawGames :: [RawGame] -> [Game]
preprocessRawGames = map preprocessRawGame
    where preprocessRawGame rawGame = Game 
            { tags         = calcTags $ rawTags rawGame
            , arrangements = calcArrangements $ rawMoves rawGame
            , winner       = rawWinner rawGame            
            }