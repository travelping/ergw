DIAGRAMS_SRC := $(wildcard diagrams/*.puml)
DIAGRAMS_SVG := $(addsuffix .svg, $(basename $(DIAGRAMS_SRC)))
DIAGRAMS_PNG := $(addsuffix .png, $(basename $(DIAGRAMS_SRC)))

DOT_FILES_SRC := $(wildcard dot_files/*.dot)
DOT_FILES_SVG := $(addsuffix .svg, $(basename $(DOT_FILES_SRC)))
DOT_FILES_PNG := $(addsuffix .png, $(basename $(DOT_FILES_SRC)))

# Default target first; build SVGs
svg: $(DIAGRAMS_SVG) $(DOT_FILES_SVG)
png: $(DIAGRAMS_PNG) $(DOT_FILES_PNG)


diagrams/%.svg: diagrams/%.puml
	plantuml -tsvg $^

diagrams/%.png: diagrams/%.puml
	plantuml -tpng $^

dot_files/%.svg: dot_files/%.dot
	dot -Tsvg $^ -o $(basename $^).svg

dot_files/%.png: dot_files/%.dot
	dot -Tpng $^ -o $(basename $^).png

clean:
	rm -f $(DIAGRAMS_PNG) $(DIAGRAMS_SVG) $(DOT_FILES_PNG) $(DOT_FILES_SVG)

.PHONY: png svg clean
