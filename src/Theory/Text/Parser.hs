{-# LANGUAGE TupleSections #-}
-- |
-- Copyright   : (c) 2010-2012 Simon Meier, Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : portable
--
-- Parsing protocol theories.
module Theory.Text.Parser (
    parseOpenTheory
  , parseOpenTheoryString
  , parseProofMethod
  , parseLemma
  , parseIntruderRulesDH
  ) where

import           Prelude                hiding (id, (.))

import qualified Data.ByteString.Char8  as BC
import           Data.Char              (toUpper, isUpper, isDigit)
import           Data.Foldable          (asum)
import           Data.Label
import qualified Data.Map               as M
import           Data.Monoid
import qualified Data.Set               as S

import           Control.Applicative    hiding (empty, many, optional)
import           Control.Category
import           Control.Monad

import           Text.Parsec            hiding (token, (<|>), string )
import qualified Text.Parsec            as P
import           Text.Parsec.Pos
import           Text.PrettyPrint.Class (render)

import           Term.Substitution
import           Term.SubtermRule
import           Theory
import           Theory.Text.Lexer
                   ( Keyword(..), TextType(..), runAlex, AlexPosn(..)
                   , alexGetPos, alexMonadScan
                   )


------------------------------------------------------------------------------
-- Specializing Parsec to our needs
------------------------------------------------------------------------------

-- Scanner
----------

-- | The tokens delivered by our Alex based scanner
type Token = (SourcePos, Keyword)

-- | Scan a string using the given filename in the error messages.
--
-- NOTE: Lexical errors are thrown using 'error'.
scanString :: FilePath -> String -> [Token]
scanString filename s =
  case runAlex s gatherUntilEOF of
    Left err  -> error err
    Right kws -> kws
  where
  gatherUntilEOF = do
    AlexPn _ line col <- alexGetPos
    let pos = newPos filename line col
    k <- alexMonadScan
    case k of
      EOF -> return [(pos,EOF)]
      _   -> do kws <- gatherUntilEOF
                return $ (pos,k) : kws

-- Parser
---------

-- | A parser for a stream of tokens.
type Parser a = Parsec [Token] MaudeSig a

-- | Parse a token based on the acceptance condition
token :: (Keyword -> Maybe a) -> Parser a
token p = P.token (show . snd) fst (p . snd)

-- | Parse a term.
kw :: Keyword -> Parser ()
kw t = token check
  where
  check t' | t == t' = Just () | otherwise = Nothing

-- | Parse content between keywords.
betweenKWs :: Keyword -> Keyword -> Parser a -> Parser a
betweenKWs l r = between (kw l) (kw r)

{-
-- | Between braces.
braced :: Parser a -> Parser a
braced = betweenKWs LBRACE RBRACE
-}

-- | Between parentheses.
parens :: Parser a -> Parser a
parens = betweenKWs LPAREN RPAREN

-- | Between single quotes.
singleQuoted :: Parser a -> Parser a
singleQuoted = betweenKWs SQUOTE SQUOTE

-- | Between double quotes.
doubleQuoted :: Parser a -> Parser a
doubleQuoted = betweenKWs DQUOTE DQUOTE

-- | Parse an identifier as a string
identifier :: Parser String
identifier = token extract
  where extract (IDENT name)
         -- don't allow certain reserved words as identifiers
         | not (name `elem` ["in","let","rule"]) = Just name
        extract _                                = Nothing

-- | Parse an identifier as a string
string :: String -> Parser ()
string cs = token extract
  where extract (IDENT name) | cs == name = Just ()
        extract _                         = Nothing

-- | Parse a sequence of fixed strings.
strings :: [String] -> Parser ()
strings = mapM_ string

-- | Parse an integer.
integer :: Parser Int
integer = do i <- identifier
             guard (all isDigit i)
             return (read i)

-- | A comma separated list of elements.
commaSep :: Parser a -> Parser [a]
commaSep = (`sepBy` kw COMMA)

{-
-- | A comma separated non-empty list of elements.
commaSep1 :: Parser a -> Parser [a]
commaSep1 = (`sepBy1` kw COMMA)
-}

-- | Parse a list of items '[' item ',' ... ',' item ']'
list :: Parser a -> Parser [a]
list p = kw LBRACKET *> commaSep p <* kw RBRACKET

-- | A formal comment; i.e., (header, body)
formalComment :: Parser (String, String)
formalComment =
    (,) <$> text begin
        <*> (concat <$> many (text content) <* text end)
  where
    text f = token (\t -> case t of TEXT ty -> f ty; _ -> mzero)
    begin (TextBegin str)     = return str
    begin _                   = mzero
    content (TextContent str) = return str
    content _                 = mzero
    end (TextEnd)             = return ()
    end _                     = mzero


------------------------------------------------------------------------------
-- Lexing and parsing theory files and proof methods
------------------------------------------------------------------------------

-- | Parser a file.
parseFile :: Parser a -> FilePath -> IO a
parseFile parser f = do
  s <- readFile f
  case runParser parser minimalMaudeSig f (scanString f s) of
    Right p -> return p
    Left err -> error $ show err

-- | Parse a security protocol theory file.
parseOpenTheory :: [String] -- ^ Defined flags
                -> FilePath -> IO OpenTheory
parseOpenTheory flags = parseFile (theory flags)

-- | Parse DH intruder rules.
parseIntruderRulesDH :: FilePath -> IO [IntrRuleAC]
parseIntruderRulesDH = parseFile (setState dhMaudeSig >> many intrRule)

-- | Parse a security protocol theory file.
-- TODO: This function seems to parse a string, not a file from a file path?
parseProofMethod :: FilePath -> Either ParseError ProofMethod
parseProofMethod =
    runParser proofMethod minimalMaudeSig dummySource . scanString dummySource
  where
    dummySource = "<interactive>"

-- | Parse a security protocol theory from a string.
parseOpenTheoryString :: [String]  -- ^ Defined flags.
                      -> String -> Either ParseError OpenTheory
parseOpenTheoryString flags = parseFromString (theory flags)

-- | Parse a lemma for an open theory from a string.
parseLemma :: String -> Either ParseError (Lemma ProofSkeleton)
parseLemma = parseFromString lemma

-- | Run a given parser on a given string.
parseFromString :: Parser a -> String -> Either ParseError a
parseFromString parser =
    runParser parser minimalMaudeSig dummySource . scanString dummySource
  where
    dummySource = "<interactive>"

------------------------------------------------------------------------------
-- Parsing Terms
------------------------------------------------------------------------------


{-
BNF:  Not completely up to date...

theory      := 'theory' ident 'begin' protocol 'end'
protocol    := rules
rules       := rule | rule rules
intrrule    := ident '[' intrinfo ']' ':' terms '-->' terms
intrinfo    := 'Destr' | 'Constr'
protorule   := ident ':' factList '-->' factList
factList    := '[' [facts] ']'
facts       := fact | fact ',' facts
protoFact   := ident '(' terms ')'
terms       := term | term ',' terms
term        := lit | application | '<' term ',' terms '>'  -- right assoc pairing
application := ident '(' terms ')'
lit        := ident | '\'' ident '\''
ident       := <a-zA-Z> (<a-zA-Z0-9-_)


// example protocol rule

  Init_1:
    [ Pub(I), Pub(R), Fresh(ni) ]
    -->
    [ Init_1(I,R,ni), Send(encA(pk(R), <I,R,ni>)) ]

// example intruder rule

  Exp [Constr]:
    [ (x^_((x1*x2))), ((x3*x1)*_x4) ]
    -->
    [ (x^(x3*_((x4*x2)))) ]

-}

------------------------------------------------------------------------------
-- Parsing Terms
------------------------------------------------------------------------------

-- | Parse an identifier possibly indexed with a number.
indexedIdentifier :: Parser (String, Integer)
indexedIdentifier = do
    (,) <$> identifier
        <*> option 0 (try (kw DOT *> (fromIntegral <$> integer)))

-- | Parse a logical variable with the given sorts allowed.
sortedLVar :: [LSort] -> Parser LVar
sortedLVar ss =
    asum $ map (try . mkSuffixParser) ss ++ map mkPrefixParser ss
  where
    mkSuffixParser s = do
        (n, i) <- indexedIdentifier
        kw COLON
        string (sortSuffix s)
        return (LVar n s i)

    mkPrefixParser s = do
        case s of
          LSortMsg   -> pure ()
          LSortPub   -> kw DOLLAR
          LSortFresh -> kw TILDE
          LSortNode  -> kw SHARP
          LSortMSet  -> kw PERCENT
        (n, i) <- indexedIdentifier
        return (LVar n s i)

-- | An arbitrary logical variable.
lvar :: Parser LVar
lvar = sortedLVar [minBound..]

-- | Parse a non-node variable.
msgvar :: Parser LVar
msgvar = sortedLVar [LSortFresh, LSortPub, LSortMsg, LSortMSet]

-- | Parse a graph node variable.
nodevar :: Parser NodeId
nodevar = asum
  [ sortedLVar [LSortNode]
  , (\(n, i) -> LVar n LSortNode i) <$> indexedIdentifier ]
  <?> "node"

-- | Parse an lit with logical variables.
llit :: Parser LNTerm
llit = asum
    [ freshTerm  <$> try (kw TILDE *> singleQuoted identifier) <?> "fresh name"
    , pubTerm    <$> singleQuoted identifier                  <?> "public name"
    , varTerm    <$> msgvar
    ]

-- | Lookup the arity of a non-ac symbol. Fails with a sensible error message
-- if the operator is not known.
lookupNonACArity :: String -> Parser Int
lookupNonACArity op = do
    maudeSig <- getState
    case lookup (BC.pack op) (S.toList $ allFunctionSymbols maudeSig) of
        Nothing -> fail $ "unknown operator `" ++ op ++ "'"
        Just k  -> return k

-- | Parse an n-ary operator application for arbitrary n.
naryOpApp :: Ord l => Parser (Term l) -> Parser (Term l)
naryOpApp plit = do
    op <- identifier
    k  <- lookupNonACArity op
    ts <- parens $ if k == 1
                     then return <$> tupleterm plit
                     else sepBy (multterm plit) (kw COMMA)
    let k' = length ts
    when (k /= k') $
        fail $ "operator `" ++ op ++"' has arity " ++ show k ++
               ", but here it is used with arity " ++ show k'
    return $ fAppNonAC (BC.pack op, k') ts

-- | Parse a binary operator written as @op{arg1}arg2@.
binaryAlgApp :: Ord l => Parser (Term l) -> Parser (Term l)
binaryAlgApp plit = do
    op <- identifier
    k <- lookupNonACArity op
    arg1 <- kw LBRACE *> tupleterm plit <* kw RBRACE
    arg2 <- term plit
    when (k /= 2) $ fail $
      "only operators of arity 2 can be written using the `op{t1}t2' notation"
    return $ fAppNonAC (BC.pack op, 2) [arg1, arg2]

-- | Parse a term.
term :: Ord l => Parser (Term l) -> Parser (Term l)
term plit = asum
    [ pairing       <?> "pairs"
    , parens (multterm plit)
    , string "1" *> pure fAppOne
    , application <?> "function application"
    , nullaryApp
    , plit
    ]
    <?> "term"
  where
    application = asum $ map (try . ($ plit)) [naryOpApp, binaryAlgApp]
    pairing = kw LESS *> tupleterm plit <* kw GREATER
    nullaryApp = do
      maudeSig <- getState
      asum [ try (string (BC.unpack sym)) *> pure (fApp (NonAC (sym,0)) [])
           | (sym,0) <- S.toList $ allFunctionSymbols maudeSig ]

-- | A left-associative sequence of exponentations.
expterm :: Ord l => Parser (Term l) -> Parser (Term l)
expterm plit = chainl1 (term plit) ((\a b -> fAppExp (a,b)) <$ kw HAT)

-- | A left-associative sequence of multiplications.
multterm :: Ord l => Parser (Term l) -> Parser (Term l)
multterm plit = do
    dh <- enableDH <$> getState
    if dh -- if DH is not enabled, do not accept 'multterm's and 'expterm's
        then chainl1 (expterm plit) ((\a b -> fAppMult [a,b]) <$ kw STAR)
        else term plit

-- | A right-associative sequence of tuples.
tupleterm :: Ord l => Parser (Term l) -> Parser (Term l)
tupleterm plit = chainr1 (multterm plit) ((\a b -> fAppPair (a,b))<$ kw COMMA)

-- | Parse a fact.
fact :: Ord l => Parser (Term l) -> Parser (Fact (Term l))
fact plit =
    do multi <- option Linear (kw BANG *> pure Persistent)
       i     <- identifier
       case i of
         []                -> fail "empty identifier"
         (c:_) | isUpper c -> return ()
               | otherwise -> fail "facts must start with upper-case letters"
       ts    <- parens (sepBy (multterm plit) (kw COMMA))
       mkProtoFact multi i ts
    <?> "protocol fact"
  where
    singleTerm _ constr [t] = return $ constr t
    singleTerm f _      ts  = fail $ "fact '" ++ f ++ "' used with arity " ++
                                     show (length ts) ++ " instead of arity one"

    mkProtoFact multi f = case map toUpper f of
      "OUT" -> singleTerm f outFact
      "IN"  -> singleTerm f inFact
      "KU"  -> return . Fact KUFact
      "KD"  -> return . Fact KDFact
      "DED" -> return . Fact DedFact
      "FR"  -> singleTerm f freshFact
      _     -> return . protoFact multi f


------------------------------------------------------------------------------
-- Parsing Rules
------------------------------------------------------------------------------

-- | Parse a "(modulo ..)" information.
modulo :: String -> Parser ()
modulo thy = parens $ strings ["modulo", thy]

moduloE, moduloAC :: Parser ()
moduloE  = modulo "E"
moduloAC = modulo "AC"

{-
-- | Parse a typing assertion modulo E.
typeAssertions :: Parser TypingE
typeAssertions = fmap TypingE $
    do try (strings ["type", "assertions"])
       optional moduloE
       kw COLON
       many1 ((,) <$> (try (msgvar <* kw COLON))
                  <*> ( commaSep1 (try $ multterm llit) <|>
                        (kw MINUS *> pure [])
                      )
             )
    <|> pure []
-}

-- | Parse a protocol rule. For the special rules 'Reveal_fresh', 'Fresh',
-- 'Knows', and 'Learn' no rule is returned as the default theory already
-- contains them.
protoRule :: Parser (ProtoRuleE)
protoRule = do
    name  <- try (string "rule" *> optional moduloE *> identifier <* kw COLON)
    subst <- option emptySubst letBlock
    (ps,as,cs) <- genericRule
    return $ apply subst $ Rule (StandRule name) ps cs as

-- | Parse a let block with bottom-up application semantics.
letBlock :: Parser LNSubst
letBlock = do
    toSubst <$> (string "let" *> many1 definition <* string "in")
  where
    toSubst = foldr1 compose . map (substFromList . return)
    definition = (,) <$> (sortedLVar [LSortMsg] <* kw EQUAL) <*> multterm llit

-- | Parse an intruder rule.
intrRule :: Parser IntrRuleAC
intrRule = do
    info <- try (string "rule" *> moduloAC *> intrInfo <* kw COLON)
    (ps,as,cs) <- genericRule
    return $ Rule info ps cs as
  where
    intrInfo = do
        name <- identifier
        case name of
          'c':cname -> return $ ConstrRule cname
          'd':dname -> return $ DestrRule dname
          _         -> fail $ "invalid intruder rule name '" ++ name ++ "'"

genericRule :: Parser ([LNFact], [LNFact], [LNFact])
genericRule =
    (,,) <$> list (fact llit)
         <*> ((pure [] <* kw LONGRIGHTARROW) <|>
              (kw MINUS *> kw MINUS *> list (fact llit) <* kw RIGHTARROW))
         <*> list (fact llit)

{-
-- | Add facts to a rule.
addFacts :: String        -- ^ Command to be used: add_concs, add_prems
         -> Parser (String, [LNFact])
addFacts cmd =
    (,) <$> (string cmd *> identifier <* kw COLON) <*> commaSep1 fact
-}

------------------------------------------------------------------------------
-- Parsing transfer notation
------------------------------------------------------------------------------

{-
-- | Parse an lit with strings for both constants as well as variables.
tlit :: Parser TTerm
tlit = asum
    [ constTerm <$> singleQuoted identifier
    , varTerm  <$> identifier
    ]

-- | Parse a single transfer.
transfer :: Parser Transfer
transfer = do
  tf <- (\l -> Transfer l Nothing Nothing) <$> identifier <* kw DOT
  (do right <- kw RIGHTARROW *> identifier <* kw COLON
      desc <- transferDesc
      return $ tf { tfRecv = Just (desc right) }
   <|>
   do right <- kw LEFTARROW *> identifier <* kw COLON
      descr <- transferDesc
      (do left <- try $ identifier <* kw LEFTARROW <* kw COLON
          descl <- transferDesc
          return $ tf { tfSend = Just (descr right)
                      , tfRecv = Just (descl left) }
       <|>
       do return $ tf { tfSend = Just (descr right) }
       )
   <|>
   do left <- identifier
      (do kw RIGHTARROW
          (do right <- identifier <* kw COLON
              desc <- transferDesc
              return $ tf { tfSend = Just (desc left)
                          , tfRecv = Just (desc right) }
           <|>
           do descl <- kw COLON *> transferDesc
              (do right <- kw RIGHTARROW *> identifier <* kw COLON
                  descr <- transferDesc
                  return $ tf { tfSend = Just (descl left)
                              , tfRecv = Just (descr right) }
               <|>
               do return $ tf { tfSend = Just (descl left) }
               )
           )
       <|>
       do kw LEFTARROW
          (do desc <- kw COLON *> transferDesc
              return $ tf { tfRecv = Just (desc left) }
           <|>
           do right <- identifier <* kw COLON
              desc <- transferDesc
              return $ tf { tfSend = Just (desc right)
                          , tfRecv = Just (desc left) }
           )
       )
    )
  where
    transferDesc = do
        ts        <- tupleterm tlit
        moreConcs <- (string "note" *> many1 (try $ fact tlit))
                     <|> pure []
        types     <- typeAssertions
        return $ \a -> TransferDesc a ts moreConcs types


-- | Parse a protocol in transfer notation
transferProto :: Parser [ProtoRuleE]
transferProto = do
    name <- string "anb" *> kw MINUS *> string "proto" *> identifier
    braced (convTransferProto name <$> abbrevs <*> many1 transfer)
  where
    abbrevs = (string "let" *> many1 abbrev) <|> pure []
    abbrev = (,) <$> try (identifier <* kw EQUAL) <*> multterm tlit

-}

------------------------------------------------------------------------------
-- Parsing Proofs
------------------------------------------------------------------------------

{-
-- | Parse a node premise.
nodePrem :: Parser NodePrem
nodePrem = NodePrem <$> parens ((,) <$> nodevar <*> (kw COMMA *> integer))

-- | Parse a node conclusion.
nodeConc :: Parser NodeConc
nodeConc = NodeConc <$> parens ((,) <$> nodevar <*> (kw COMMA *> integer))
-}


-- | Parse the @\@@ requires operator.
actionOp :: Parser ()
actionOp = try (kw AT)

-- | Parse the @<@ temporal less operator.
lessOp :: Parser ()
lessOp = try (kw LESS)

-- | Parse the @=@ equal operator.
equalOp :: Parser ()
equalOp = kw APPROX <|> kw EQUAL

{-
-- | Parse the @--|@ deduced before operator.
dedBeforeOp :: Parser ()
dedBeforeOp = try (kw MINUS *> kw MINUS *> kw MID)

-- | Parse the @<@ temporal less operator.
edgeOp :: Parser ()
edgeOp = try (kw GREATER *> kw RIGHTARROW)

-- | Parse the @~~>@ chain operator.
chainOp :: Parser ()
chainOp = kw TILDE *> kw TILDE *> kw TILDE *> kw GREATER
-}

-- | Parse a goal.
goal :: Parser Goal
goal = fail "SM: reimplement goal parsing" {- asum
  [ splitGoal
  , premiseGoal
  , chainGoal
  ]
  where
    premiseGoal = try $ do
        v  <- nodevar
        i  <- brackets integer <* requiresOp
        fa <- fact llit
        return $ PremiseGoal fa (NodePrem (v, i))

    chainGoal = ChainGoal
        <$> (try $ term llit <* kw COLON)
        <*> (Chain <$> (nodeConc <* chainOp) <*> nodePrem)

    splitGoal = do
        split <- (string "splitEqsOn"    *> pure SplitEqs) <|>
                 (string "splitTypingOn" *> pure SplitTyping)
        SplitGoal split <$> parens integer
-}

-- | Parse a proof method.
proofMethod :: Parser ProofMethod
proofMethod = optional (kw BANG) *> asum
  [ string "sorry"         *> pure (Sorry "not yet proven")
  , string "simplify"      *> pure Simplify
  , string "solve"         *> (SolveGoal <$> parens goal)
  , string "contradiction" *> pure (Contradiction Nothing)
  ]

-- | Parse a proof skeleton.
proofSkeleton :: Parser ProofSkeleton
proofSkeleton =
    finalProof <|> interProof
  where
    finalProof = do
        method <- string "by" *> proofMethod
        return (LNode (ProofStep method ()) M.empty)

    interProof = do
        method <- proofMethod
        cases  <- (sepBy oneCase (string "next") <* string "qed") <|>
                  ((return . ("",)) <$> proofSkeleton           )
        return (LNode (ProofStep method ()) (M.fromList cases))

    oneCase = (,) <$> (string "case" *> identifier) <*> proofSkeleton

------------------------------------------------------------------------------
-- Parsing Formulas and Lemmas
------------------------------------------------------------------------------

-- | Parse an atom with possibly bound logical variables.
blatom :: Parser BLAtom
blatom = (fmap (fmapTerm (fmap Free))) <$> asum
  [ flip Action <$> try (fact llit <* actionOp) <*> nodevarTerm      <?> "action"
  , Less        <$> try (nodevarTerm <* lessOp)    <*> nodevarTerm   <?> "less"
  , EqE         <$> try (multterm llit <* equalOp) <*> multterm llit <?> "term equality"
  , EqE         <$>     (nodevarTerm  <* equalOp)  <*> nodevarTerm   <?> "node equality"
  ]
  where
    nodevarTerm = (lit . Var) <$> nodevar
    -- nodePrem = annNode PremIdx
    -- nodeConc = annNode ConcIdx
    -- annNode mkAnn = parens ((,) <$> (nodevarTerm <* kw COMMA)
    --                             <*> (mkAnn <$> integer))

-- | Parse an atom of a formula.
fatom :: Parser (LFormula Name)
fatom = asum
  [ pure lfalse <* string "F"
  , pure ltrue  <* string "T"
  , Ato <$> try blatom
  , quantification
  , parens iff
  ]
  where
    quantification = do
        q <- (pure forall <* (kw FORALL <|> string "All")) <|>
             (pure exists <* (kw EXISTS <|> string "Ex") )
        vs <- many1 lvar <* kw DOT
        f  <- iff
        return $ foldr (hinted q) f vs

    hinted :: ((String, LSort) -> LVar -> a) -> LVar -> a
    hinted f v@(LVar n s _) = f (n,s) v



-- | Parse a negation.
negation :: Parser (LFormula Name)
negation = ((kw LNOT <|> string "not") *> (Not <$> fatom)) <|> fatom

-- | Parse a left-associative sequence of conjunctions.
conjuncts :: Parser (LFormula Name)
conjuncts = chainl1 negation ((.&&.) <$ (kw LAND <|> kw AND))

-- | Parse a left-associative sequence of disjunctions.
disjuncts :: Parser (LFormula Name)
disjuncts = chainl1 conjuncts ((.||.) <$ (kw LOR <|> kw MID))

-- | An implication.
imp :: Parser (LFormula Name)
imp = do
  lhs <- disjuncts
  asum [ try (kw EQUAL *> kw EQUAL *> kw GREATER) *>
             ((lhs .==>.) <$> imp)
       , pure lhs ]

-- | An logical equivalence.
iff :: Parser (LFormula Name)
iff = do
  lhs <- imp
  asum [ try (kw LESS *> kw EQUAL *> kw GREATER) *>
             ((lhs .<=>.) <$> imp)
       , pure lhs ]

-- | Parse a 'LemmaAttribute'.
lemmaAttribute :: Parser LemmaAttribute
lemmaAttribute = asum
  [ string "typing"    *> pure TypingLemma
  , string "reuse"     *> pure ReuseLemma
  , string "invariant" *> pure InvariantLemma
  ]

-- | Parse a 'TraceQuantifier'.
traceQuantifier :: Parser TraceQuantifier
traceQuantifier = asum
  [ string "all"    *> kw MINUS *> string "traces" *> pure AllTraces
  , string "exists" *> kw MINUS *> string "trace"  *> pure ExistsTrace
  ]

-- | Parse a lemma.
lemma :: Parser (Lemma ProofSkeleton)
lemma = skeletonLemma <$> (string "lemma" *> optional moduloE *> identifier)
                      <*> (option [] $ list lemmaAttribute)
                      <*> (kw COLON *> option AllTraces traceQuantifier)
                      <*> doubleQuoted iff
                      <*> (proofSkeleton <|> pure (unproven ()))

-- | Builtin signatures.
builtins :: Parser ()
builtins =
    string "builtins" *> kw COLON *> sepBy1 builtinTheory (kw COMMA) *> pure ()
  where
    extendSig msig = modifyState (`mappend` msig)
    builtinTheory = asum
      [ try (string "diffie"     *> kw MINUS *> string "hellman")
          *> extendSig dhMaudeSig
      , try (string "symmetric"  *> kw MINUS *> string "encryption")
          *> extendSig symEncMaudeSig
      , try (string "asymmetric" *> kw MINUS *> string "encryption")
          *> extendSig asymEncMaudeSig
      , try (string "signing")
          *> extendSig signatureMaudeSig
      , string "hashing"
          *> extendSig hashMaudeSig
      ]

functions :: Parser ()
functions =
    string "functions" *> kw COLON *> sepBy1 functionSymbol (kw COMMA) *> pure ()
  where
    functionSymbol = do
        funsym <- (,) <$> (BC.pack <$> identifier) <*> (kw SLASH *> integer)
        sig <- getState
        case lookup (fst funsym) (S.toList $ allFunctionSymbols sig) of
          Just k | k /= snd funsym ->
            fail $ "conflicting arities " ++
                   show k ++ " and " ++ show (snd funsym) ++
                   " for `" ++ BC.unpack (fst funsym)
          _ -> setState (addFunctionSymbol funsym sig)

equations :: Parser ()
equations =
    string "equations" *> kw COLON *> sepBy1 equation (kw COMMA) *> pure ()
  where
    equation = do
        rrule <- RRule <$> term llit <*> (kw EQUAL *> term llit)
        case rRuleToStRule rrule of
          Just str ->
              modifyState (addStRule str)
          Nothing  ->
              fail $ "Not a subterm rule: " ++ show rrule

------------------------------------------------------------------------------
-- Parsing Theories
------------------------------------------------------------------------------


-- | Parse a theory.
theory :: [String]   -- ^ Defined flags.
       -> Parser OpenTheory
theory flags0 = do
    string "theory"
    thyId <- identifier
    string "begin"
        *> addItems (S.fromList flags0) (set thyName thyId defaultOpenTheory)
        <* string "end"
  where
    addItems :: S.Set String -> OpenTheory -> Parser OpenTheory
    addItems flags thy = asum
      [ do builtins
           msig <- getState
           addItems flags $ set (sigpMaudeSig . thySignature) msig thy
      , do functions
           msig <- getState
           addItems flags $ set (sigpMaudeSig . thySignature) msig thy
      , do equations
           msig <- getState
           addItems flags $ set (sigpMaudeSig . thySignature) msig thy
--      , do thy' <- foldM liftedAddProtoRule thy =<< transferProto
--           addItems flags thy'
      , do thy' <- liftedAddLemma thy =<< lemma
           addItems flags thy'
      , do ru <- protoRule
           thy' <- liftedAddProtoRule thy ru
           addItems flags thy'
      , do r <- intrRule
           addItems flags (addIntrRuleACs [r] thy)
      , do c <- formalComment
           addItems flags (addFormalComment c thy)
      , do ifdef flags thy
      , do define flags thy
      , do return thy
      ]

    define :: S.Set String -> OpenTheory -> Parser OpenTheory
    define flags thy = do
       flag <- try (kw SHARP *> string "define") *> identifier
       addItems (S.insert flag flags) thy

    ifdef :: S.Set String -> OpenTheory -> Parser OpenTheory
    ifdef flags thy = do
       flag <- try (kw SHARP *> string "ifdef") *> identifier
       thy' <- addItems flags thy
       try (kw SHARP *> string "endif")
       if flag `S.member` flags
         then addItems flags thy'
         else addItems flags thy

    liftedAddProtoRule thy ru = case addProtoRule ru thy of
        Just thy' -> return thy'
        Nothing   -> fail $ "duplicate rule: " ++ render (prettyRuleName ru)

    liftedAddLemma thy l = case addLemma l thy of
        Just thy' -> return thy'
        Nothing   -> fail $ "duplicate lemma: " ++ get lName l