qGames Chess — piece set
========================

These twelve SVG files are the pieces. Edit them in any vector editor and
restart the game; there is nothing to rebuild and nothing to install.

  wK wQ wR wB wN wP   white king, queen, rook, bishop, knight, pawn
  bK bQ bR bB bN bP   the same in black

To keep a set under version control and ship it inside every build, put it in
the repository at games/chess/assets/pieces/ instead — `make chess-pieces-repo`
writes it there with the .import stubs it needs. Without those stubs the set
works in the editor and is silently missing from every exported build.

Each generated file carries one marker comment near the top. Delete that line
when you edit a piece: it is what tells the test suite the file is yours and
should no longer be checked against the artwork drawn in code.

Delete a file and that piece falls back to the one drawn in code, so you can
replace them one at a time. Delete all of them and you get the built-in set
back. Re-run with --dump-pieces to start over from the built-in artwork.

The viewBox is the box the built-in art occupies. Anything you draw is fitted
to the square with its aspect preserved and centred, so a different canvas
shape is safe — it will not be stretched.

These names are the convention every chess program uses, so a set downloaded
from elsewhere can be dropped in here unrenamed.
