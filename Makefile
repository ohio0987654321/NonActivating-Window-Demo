APP_NAME = Window
BUILD_DIR = build
OBJ_DIR = $(BUILD_DIR)/obj
EXEC = $(BUILD_DIR)/$(APP_NAME)

CC = clang
CFLAGS = -g -fobjc-arc
FRAMEWORKS = -framework Cocoa

SOURCES = src/main.m src/AppDelegate.m
OBJECTS = $(patsubst src/%.m,$(OBJ_DIR)/%.o,$(SOURCES))

all: app

$(BUILD_DIR) $(OBJ_DIR):
	mkdir -p $@

$(OBJ_DIR)/%.o: src/%.m | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(EXEC): $(OBJECTS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(OBJECTS) -o $@

app: $(EXEC)

clean:
	rm -rf $(BUILD_DIR)

run: app
	$(EXEC)

.PHONY: all app clean run