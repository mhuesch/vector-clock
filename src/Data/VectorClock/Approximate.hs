{-# LANGUAGE Trustworthy, DeriveDataTypeable, DeriveGeneric #-}

-- | An approximate vector clock implementation in terms of
-- "Data.VectorClock.Simple".

module Data.VectorClock.Approximate (
        -- * Usage example
        -- $example

        -- * Vector clock type
        VectorClock,
        -- * Construction
        empty, singleton, fromList, toList,
        -- * Query
        null, size, member, lookup,
        -- * Insertion
        insert, inc, incWithDefault,
        -- * Deletion
        delete,
        -- * Merges
        combine, max, diff,
        -- * Relations
        Relation(..), relation, causes,
        -- * Debugging
        valid
    ) where

import Prelude hiding ( null, lookup, max )
import qualified Prelude

import Control.Applicative ( (<$>) )
import Data.Binary ( Binary(..) )
import Data.Data ( Data, Typeable )
import Data.Foldable ( Foldable(foldMap), foldl' )
import Data.Hashable ( Hashable, hash )
import Data.Traversable ( Traversable(..) )
import GHC.Generics ( Generic )

import Data.VectorClock.Simple ( Relation(..) )
import qualified Data.VectorClock.Simple as VC

-- $example
--
-- See "Data.VectorClock.Simple" for a more detailed example of using
-- vector clock.
--
-- An approximate vector clock, is like a normal one, but maps
-- multiple keys to the same entry.  Concretely, this is done by first
-- hashing the keys, then using them modulo the vector clock's size.
-- So, an approximate vector clock of size 1 would map all the keys to
-- the same entry; an approximate vector clock of size 2 would map
-- roughly half its keys to the first entry, and half to the second
-- entry.
--
-- To create an approximate vector clock, start from 'empty' and
-- 'insert' elements into it.  As a shortcut, 'fromList' just inserts
-- all the elements in a list, in order.  You must also specify the
-- vector clock's maximum size when creating it.  Experimental results
-- suggest that small maximum sizes (e.g. 3 or 4) will yield good
-- resulsts in practice.  Higher maximum sizes will have no adverse
-- effects, and will effectively turn approximate vector clocks into
-- normal ones.
--
-- > let vc = empty 4 in
-- > let vc' = insert 'a' 1 vc in
-- > let vc'' = insert 'b' 2 vc in
-- > vc'' == fromList 4 [('a', 1), ('b', 2)]

-- | An approximate vector clock is a normal vector clock, but several
-- keys are mapped to the same value.  This can lead to /false/
-- /positive/ 'relation's.  In other words, the fact that one vector
-- clock causes another is no longer enough information to say that
-- one message causes the other.  That said, experimental results show
-- that approximate vector clocks have good results in practice; see
-- the paper by R. Baldoni and M. Raynal for details.
data VectorClock a b = VectorClock
    { vcClock :: VC.VectorClock Int b
    , vcSize  :: Int
    } deriving ( Data, Typeable, Generic )

instance (Eq b) => Eq (VectorClock a b) where
    vc1 == vc2 = vcClock vc1 == vcClock vc2

instance (Show b) => Show (VectorClock a b) where
    show = show . vcClock

instance (Binary b) => Binary (VectorClock a b) where
    put vc = do
        put (vcClock vc)
        put (vcSize vc)
    get = do
        xys <- get
        k <- get
        return (VectorClock { vcClock = xys, vcSize = k })

instance Foldable (VectorClock a) where
    foldMap f = foldMap f . vcClock

instance Functor (VectorClock a) where
    fmap f vc = vc { vcClock = fmap f (vcClock vc) }

instance Traversable (VectorClock a) where
    traverse f vc = (\xys -> vc { vcClock = xys }) <$> traverse f (vcClock vc)

-- | /O(1)/.  The empty vector clock.
empty :: Int                    -- ^ /size/: the maximum number of
                                -- entries in the vector clock
      -> VectorClock a b
empty k = VectorClock { vcClock = VC.empty, vcSize = k }

-- | /O(N)/.  Insert each entry in the list one at a time.
fromList :: (Hashable a)
         => Int                 -- ^ /size/: the maximum number of
                                -- entries in the vector clock
         -> [(a, b)]            -- ^ /entries/: the entries to insert
                                -- in the newly created vector clock
         -> VectorClock a b
fromList k = foldl' (\vc (x, y) -> insert x y vc) (empty k)

-- | /O(1)/.  All the entries in the vector clock.  Note that this is
-- /not/ the inverse of 'fromList'.  Note that the keys are returned
-- /hashed/.
toList :: VectorClock a b -> [(Int, b)]
toList = VC.toList . vcClock

-- | /O(1)/.  A vector clock with a single element.
singleton :: (Hashable a)
          => Int                -- ^ /size/: the maximum number of
                                -- entries in the vector clock
          -> a                  -- ^ /key/: the key for the entry
          -> b                  -- ^ /value/: the value for the entry
          -> VectorClock a b
singleton k x y = fromList k [(x, y)]

-- | /O(1)/.  Is the vector clock empty?
null :: VectorClock a b -> Bool
null = VC.null . vcClock

-- | /O(N)/.  The number of entries in the vector clock.  Note that
-- this may be less than the /size/ at construction.
size :: VectorClock a b -> Int
size = VC.size . vcClock

-- | /O(N)/.  Is the given key a key in an entry of the vector clock?
member :: (Hashable a) => a -> VectorClock a b -> Bool
member x (VectorClock { vcClock = xys, vcSize = k }) =
    VC.member (mapKey x k) xys

-- | /O(N)/.  Lookup the value for a key in the vector clock.
lookup :: (Hashable a)  => a -> VectorClock a b -> Maybe b
lookup x (VectorClock { vcClock = xys, vcSize = k }) =
    VC.lookup (mapKey x k) xys

-- | /O(N)/.  Insert or replace the entry for a key.
insert :: (Hashable a) => a -> b -> VectorClock a b -> VectorClock a b
insert x y vc@(VectorClock { vcClock = xys, vcSize = k }) =
    let xys' = VC.insert (mapKey x k) y xys in
    vc { vcClock = xys' }

-- | /O(N)/.  Increment the entry for a key.
inc :: (Hashable a, Num b) => a -> VectorClock a b -> Maybe (VectorClock a b)
inc x vc@(VectorClock { vcClock = xys, vcSize = k }) = do
    xys' <- VC.inc (mapKey x k) xys
    return (vc { vcClock = xys' })

-- | /O(N)/.  Increment the entry for a key.  If the key does not
-- exist, assume it was the default.
incWithDefault :: (Hashable a, Num b)
               => a               -- ^ /key/: the key of the entry
               -> VectorClock a b -- ^ /vc/: the vector clock
               -> b               -- ^ /default/: if the key is not
                                  -- found, assume its value was the
                                  -- /default/ and increment that
               -> VectorClock a b
incWithDefault x vc@(VectorClock { vcClock = xys, vcSize = k }) y' =
    let xys' = VC.incWithDefault (mapKey x k) xys y' in
    vc { vcClock = xys' }

-- | /O(N)/.  Delete an entry from the vector clock.  If the requested
-- entry does not exist, does nothing.
delete :: (Hashable a) => a -> VectorClock a b -> VectorClock a b
delete x vc@(VectorClock { vcClock = xys, vcSize = k }) =
    let xys' = VC.delete (mapKey x k) xys in
    vc { vcClock = xys' }

-- | /O(max(N, M))/.  Combine two vector clocks entry-by-entry.  The
-- size of the resulting vector clock is the maximum of the sizes of
-- the given ones.
combine :: (Ord b)
        => (Int -> Maybe b -> Maybe b -> Maybe b)
    -- ^ a function that takes the hashed /key/, the value of the
    -- entry in the left hand vector clock, if it exists, the value in
    -- the right hand vector clock, if it exists, and, if it wishes to
    -- keep a value for this /key/ in the resulting vector clock,
    -- returns it.
        -> VectorClock a b      -- ^ /lhs/: the left hand vector clock
        -> VectorClock a b      -- ^ /rhs/: the right hand vector clock
        -> VectorClock a b
combine f (VectorClock { vcClock = xys1, vcSize = k1 })
          (VectorClock { vcClock = xys2, vcSize = k2 }) =
    let xys' = VC.combine f xys1 xys2 in
    VectorClock { vcClock = xys', vcSize = Prelude.max k1 k2  }

-- | /O(max(N, M))/.  The maximum of the two vector clocks.
max :: (Ord b)
    => VectorClock a b
    -> VectorClock a b
    -> VectorClock a b
max = combine maxEntry
  where
    maxEntry _ Nothing Nothing    = Nothing
    maxEntry _ x@(Just _) Nothing = x
    maxEntry _ Nothing y@(Just _) = y
    maxEntry _ (Just x) (Just y)  = Just (Prelude.max x y)

-- | /O(min(N, M))/.  The relation between the two vector clocks.
relation :: (Ord b) => VectorClock a b -> VectorClock a b -> Relation
relation (VectorClock { vcClock = xys1 }) (VectorClock { vcClock = xys2 }) =
    VC.relation xys1 xys2

-- | /O(min(N, M))/.  Short-hand for @relation vc1 vc2 == Causes@.
causes :: (Ord a, Ord b) => VectorClock a b -> VectorClock a b -> Bool
causes vc1 vc2 = relation vc1 vc2 == Causes

-- | /O(M)/.  If @vc2 `causes` vc1@, compute the smallest @vc3@
-- s.t. @max vc3 vc2 == vc1@.  Note that the /first/ parameter is the
-- newer vector clock.
diff :: (Ord a, Ord b)
     => VectorClock a b -> VectorClock a b -> Maybe (VectorClock a b)
diff vc1 vc2 = do
  xys <- VC.diff (vcClock vc1) (vcClock vc2)
  return (vc1 { vcClock = xys })

-- | Map a key into the domain of approximate keys.
mapKey :: (Hashable a) => a -> Int -> Int
mapKey x k = hash x `mod` k

-- | /O(N)/.  Check whether the vector clock is valid or not.
valid :: (Ord b) => VectorClock a b -> Bool
valid vc@(VectorClock { vcClock = xys, vcSize = k }) =
    size vc <= k && VC.valid xys
