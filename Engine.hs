module Engine where

import qualified Data.Map as M
import Control.Monad
import Data.List
import Control.Monad.RWS

type Coord = (Int,Int)

data Team = A | B
          deriving (Show, Eq)

data SoldierState = SoldierState {soldierName :: Name,
                                  soldierTeam :: Team,
                                  soldierCoord :: Coord,
                                  hasGrenade :: Bool,
                                  soldierAlive :: Bool}
                  deriving Show
                           
mkSoldier :: Name -> Team -> Coord -> SoldierState
mkSoldier n t c = SoldierState n t c True True

type Soldiers = M.Map Name SoldierState

toSoldiers :: [SoldierState] -> Soldiers
toSoldiers = M.fromList . map f
  where f s = (soldierName s, s)
        
fromSoldiers :: Soldiers -> [SoldierState]
fromSoldiers = M.elems

-- traversable?
mapMSoldiers :: Monad m => (SoldierState -> m SoldierState) -> Soldiers -> m Soldiers
mapMSoldiers f s = liftM toSoldiers $ mapM f (fromSoldiers s)

mapMNamedSoldier :: Monad m => (SoldierState -> m SoldierState) -> Name -> Soldiers -> m Soldiers
mapMNamedSoldier f name ss = case M.lookup name ss
                          of Nothing  -> return ss
                             (Just s) -> do s' <- f s
                                            return $ M.insert name s' ss
                           
data Dir = S | D | U | L | R
         deriving (Show,Read,Eq)

type Trans = (Int,Int)

trans :: Dir -> Trans
trans S = (0,0)
trans U = (0,-1)
trans D = (0,1)
trans L = (-1,0)
trans R = (1,0)

manhattan :: Coord -> Coord -> Int
manhattan (a,b) (c,d) = abs (a-c) + abs (b-d)
               
(<+>) :: Coord -> Trans -> Coord
(a,b) <+> (c,d) = (a+c,b+d)

move :: Dir -> Coord -> Coord
move d c = c <+> trans d

type Name = String

data Grenade = Grenade {grenadeCoord :: Coord, grenadeTeam :: Team, countdown :: Int}
               deriving Show

data Command = Command {commandName :: Name,
                        commandDirection :: Dir,
                        throwsGrenade :: Maybe Coord}
               deriving (Show,Eq)

data Respawn = Respawn {respawnName :: Name} deriving Show
data Explosion = Explosion Coord deriving Show

data Event = EvGrenade Grenade | EvExplosion Explosion | EvRespawn Respawn
           deriving Show
                    
type EventM = RWS () [Event] Game

runEventM :: EventM () -> Game -> (Game,[Event])
runEventM f g = execRWS f () g

pend :: Event -> EventM ()
pend = tell . (:[])

-- Commands

validCoordinate :: Coord -> Game -> Bool
validCoordinate (x,y) g = x >= 0 && y >= 0 && x < w && y < h
  where (w,h) = size . board $ g

moveSoldier :: Command -> SoldierState -> EventM SoldierState
moveSoldier c ss = 
  do let to = move (commandDirection c) (soldierCoord ss)
     ok <- gets $ validCoordinate to
     return $ if soldierAlive ss && ok
              then ss {soldierCoord = to}
              else ss

throw :: Command -> SoldierState -> EventM SoldierState
throw (Command _ _ Nothing) st = return st
throw (Command _ _ (Just coord)) st =
  do ok <- canThrow st coord
     if ok
       then do pend . EvGrenade $ Grenade coord (soldierTeam st) 2
               return st {hasGrenade = False}
       else return st

canThrow :: SoldierState -> Coord -> EventM Bool
canThrow s c = do valid <- gets $ validCoordinate c
                  return $
                    valid 
                    && hasGrenade s
                    && manhattan (soldierCoord s) c <= 10
                    
processSoldier :: Command -> SoldierState -> EventM SoldierState
processSoldier c = throw c >=> moveSoldier c

processCommand :: Command -> EventM ()
processCommand c = do new <- gets soldiers >>= mapMNamedSoldier (processSoldier c) (commandName c)
                      modify (\g -> g {soldiers = new})

processCommands :: [Command]
                   -> EventM ()
processCommands cs = mapM_ processCommand cs

-- events

kills :: SoldierState -> Explosion -> Bool
kills s (Explosion (a,b)) = abs (a-c) <= 1 && abs (b-d) <= 1
  where (c,d) = soldierCoord s

reviveSoldier :: SoldierState -> EventM SoldierState
reviveSoldier s
  | not (soldierAlive s) = do r <- gets $ respawn.board
                              return s { soldierAlive = True, soldierCoord = r (soldierTeam s) }
  | otherwise = return s

processEvents :: EventM ()
processEvents = mapM_ processEvent =<< gets pendingEvents 

processEvent :: Event -> EventM ()
processEvent (EvGrenade g)
  | countdown g == 1  = pend . EvExplosion . Explosion $ grenadeCoord g
  | otherwise         = pend $ EvGrenade g {countdown = countdown g - 1} 
processEvent (EvExplosion e) = do new <- gets soldiers >>= mapMSoldiers f
                                  modify (\g -> g {soldiers = new})
  where f s
          | kills s e = do pend . EvRespawn . Respawn $ soldierName s
                           return s {soldierAlive=False}
          | otherwise = return s
processEvent (EvRespawn (Respawn n)) = do new <- gets soldiers >>= mapMNamedSoldier reviveSoldier n
                                          modify (\g -> g {soldiers = new})
                                          
-- bring it together
  
data Board = Board {size :: (Int,Int),
                    respawn :: Team -> Coord}

data Game = Game {board :: Board,
                  soldiers :: Soldiers,
                  pendingEvents :: [Event]}

updateGame :: Game -> [Command] -> Game
updateGame g commands = g' {pendingEvents = events'}
  where (g',events') = flip runEventM g $ do processEvents
                                             processCommands commands
                         
grenades :: [Event] -> [Grenade]
grenades = concatMap f
  where f e = case e of EvGrenade g -> [g]
                        _ -> []

explosions :: [Event] -> [Explosion]       
explosions = concatMap f
  where f e = case e of EvExplosion ex -> [ex]
                        _ -> []
        
drawGame' :: Game -> M.Map Coord String
drawGame' game = M.fromListWith comb (gs++tss++es)
  where comb x y = x ++ "," ++ y
        gs = map drawGrenade . grenades . pendingEvents $ game
        drawGrenade g = (grenadeCoord g,show $ countdown g)
        es = map drawExplosion . explosions . pendingEvents $ game
        drawExplosion (Explosion c) = (c,"#")
        tss = map drawSoldier . M.assocs . soldiers $ game
        drawSoldier (name,s) = (soldierCoord s,if soldierAlive s then name else "_")
        
drawGame :: Game -> String
drawGame g = unlines $ map (intercalate " " . map d) coords
  where (w,h) = size . board $ g
        coords = map (\x -> map ((,)x) [0..h-1]) [0..w-1]
        drawn = drawGame' g
        d c = M.findWithDefault "." c drawn

gameInfo :: Game -> Team -> String
gameInfo g t = unlines $ ss ++ gs
  where ss = map show . filter ((==t).soldierTeam) . M.elems $ soldiers g
        gs = map show . filter ((==t).grenadeTeam) . grenades $ pendingEvents g
        
gamePending :: Game -> String
gamePending g = unlines $ map show $ pendingEvents g