# Obsidian Plugin API Reference

This is a condensed reference of the most important classes, interfaces, and methods from `obsidian.d.ts`. For the full type definitions, see https://github.com/obsidianmd/obsidian-api.

## Core Classes

### Plugin

Base class for all plugins. Extend this to create your plugin.

```typescript
class Plugin extends Component {
  app: App;
  manifest: PluginManifest;

  // Lifecycle
  onload(): void;
  onunload(): void;

  // Data persistence (stored in .obsidian/plugins/<id>/data.json)
  loadData(): Promise<any>;
  saveData(data: any): Promise<void>;

  // UI registration
  addRibbonIcon(icon: string, title: string, callback: (evt: MouseEvent) => any): HTMLElement;
  addStatusBarItem(): HTMLElement;
  addCommand(command: Command): Command;
  addSettingTab(settingTab: PluginSettingTab): void;

  // View registration
  registerView(type: string, viewCreator: (leaf: WorkspaceLeaf) => View): void;

  // Event registration (auto-cleanup on unload)
  registerEvent(eventRef: EventRef): void;
  registerDomEvent<K extends keyof WindowEventMap>(el: Window, type: K, callback: (this: HTMLElement, ev: WindowEventMap[K]) => any): void;
  registerInterval(id: number): number;

  // Editor extensions
  registerEditorExtension(extension: Extension): void;
  registerEditorSuggest(editorSuggest: EditorSuggest<any>): void;

  // Markdown post-processing
  registerMarkdownPostProcessor(postProcessor: MarkdownPostProcessor): MarkdownPostProcessor;
  registerMarkdownCodeBlockProcessor(language: string, handler: (source: string, el: HTMLElement, ctx: MarkdownPostProcessorContext) => Promise<any> | void): MarkdownPostProcessor;
}
```

### App

The main application object. Access via `this.app` in your plugin.

```typescript
class App {
  vault: Vault;
  workspace: Workspace;
  fileManager: FileManager;
  metadataCache: MetadataCache;
  keymap: Keymap;
  scope: Scope;
}
```

### Vault

File system operations within the vault.

```typescript
class Vault extends Events {
  // File listing
  getMarkdownFiles(): TFile[];
  getFiles(): TFile[];
  getAllLoadedFiles(): TAbstractFile[];

  // File lookup
  getAbstractFileByPath(path: string): TAbstractFile | null;
  getFileByPath(path: string): TFile | null;
  getFolderByPath(path: string): TFolder | null;

  // Read
  read(file: TFile): Promise<string>;
  cachedRead(file: TFile): Promise<string>;
  readBinary(file: TFile): Promise<ArrayBuffer>;

  // Write
  create(path: string, data: string, options?: DataWriteOptions): Promise<TFile>;
  createBinary(path: string, data: ArrayBuffer, options?: DataWriteOptions): Promise<TFile>;
  createFolder(path: string): Promise<TFolder>;
  modify(file: TFile, data: string, options?: DataWriteOptions): Promise<void>;
  modifyBinary(file: TFile, data: ArrayBuffer, options?: DataWriteOptions): Promise<void>;
  process(file: TFile, fn: (data: string) => string, options?: DataWriteOptions): Promise<string>;

  // Delete
  delete(file: TAbstractFile, force?: boolean): Promise<void>;
  trash(file: TAbstractFile, system: boolean): Promise<void>;

  // Rename/move
  rename(file: TAbstractFile, newPath: string): Promise<void>;
  copy(file: TFile, newPath: string): Promise<TFile>;

  // Events
  on(name: 'create', callback: (file: TAbstractFile) => any): EventRef;
  on(name: 'modify', callback: (file: TAbstractFile) => any): EventRef;
  on(name: 'delete', callback: (file: TAbstractFile) => any): EventRef;
  on(name: 'rename', callback: (file: TAbstractFile, oldPath: string) => any): EventRef;

  // Adapter (low-level filesystem access)
  adapter: DataAdapter;
}
```

### Workspace

Manages the layout of views and leaves.

```typescript
class Workspace extends Events {
  // Active state
  getActiveViewOfType<T extends View>(type: Constructor<T>): T | null;
  getActiveFile(): TFile | null;
  activeEditor: MarkdownFileInfo | null;

  // Leaf management
  getLeaf(newLeaf?: boolean): WorkspaceLeaf;
  getLeftLeaf(split: boolean): WorkspaceLeaf;
  getRightLeaf(split: boolean): WorkspaceLeaf;
  createLeafInParent(parent: WorkspaceParent, index: number): WorkspaceLeaf;
  getLeavesOfType(viewType: string): WorkspaceLeaf[];
  detachLeavesOfType(viewType: string): void;
  revealLeaf(leaf: WorkspaceLeaf): void;

  // Iteration
  iterateAllLeaves(callback: (leaf: WorkspaceLeaf) => any): void;
  iterateRootLeaves(callback: (leaf: WorkspaceLeaf) => any): void;

  // Editor extensions
  updateOptions(): void;

  // Events
  on(name: 'file-open', callback: (file: TFile | null) => any): EventRef;
  on(name: 'active-leaf-change', callback: (leaf: WorkspaceLeaf | null) => any): EventRef;
  on(name: 'layout-change', callback: () => any): EventRef;
  on(name: 'file-menu', callback: (menu: Menu, file: TAbstractFile, source: string, leaf?: WorkspaceLeaf) => any): EventRef;
  on(name: 'editor-menu', callback: (menu: Menu, editor: Editor, info: MarkdownView | MarkdownFileInfo) => any): EventRef;
  on(name: 'editor-change', callback: (editor: Editor, info: MarkdownView | MarkdownFileInfo) => any): EventRef;
}
```

### WorkspaceLeaf

A pane in the workspace that contains a view.

```typescript
class WorkspaceLeaf extends Component {
  view: View;

  getViewState(): ViewState;
  setViewState(viewState: ViewState, eState?: any): Promise<void>;

  getDisplayText(): string;
  getIcon(): string;

  detach(): void;
  setGroup(group: string): void;
}
```

### Editor

Interface for the text editor (wraps CodeMirror).

```typescript
interface Editor {
  getSelection(): string;
  replaceSelection(replacement: string): void;

  getValue(): string;
  setValue(content: string): void;

  getLine(line: number): string;
  setLine(line: number, text: string): void;
  lineCount(): number;

  getCursor(string?: 'from' | 'to' | 'head' | 'anchor'): EditorPosition;
  setCursor(pos: EditorPosition | number, ch?: number): void;

  getRange(from: EditorPosition, to: EditorPosition): string;
  replaceRange(replacement: string, from: EditorPosition, to: EditorPosition, origin?: string): void;

  getDoc(): any;  // CodeMirror doc
  scrollIntoView(range: EditorRange, center?: boolean): void;

  focus(): void;
  blur(): void;
  hasFocus(): boolean;

  getScrollInfo(): { top: number; left: number };
  scrollTo(x?: number | null, y?: number | null): void;

  exec(command: EditorCommandName): void;
  transaction(tx: EditorTransaction, origin?: string): void;

  wordAt(pos: EditorPosition): EditorRange | null;
  posToOffset(pos: EditorPosition): number;
  offsetToPos(offset: number): EditorPosition;
}
```

### View Types

```typescript
// Base view
abstract class View extends Component {
  app: App;
  leaf: WorkspaceLeaf;
  containerEl: HTMLElement;
  contentEl: HTMLElement;

  abstract getViewType(): string;
  abstract getDisplayText(): string;
  getIcon(): string;

  onOpen(): Promise<void>;
  onClose(): Promise<void>;
}

// Custom view for plugin panels
abstract class ItemView extends View {
  // Adds navigation buttons
  addAction(icon: string, title: string, callback: (evt: MouseEvent) => any): HTMLElement;
}

// Markdown editor/preview
class MarkdownView extends View {
  editor: Editor;
  file: TFile;
  getMode(): 'source' | 'preview';
}
```

### Modal Types

```typescript
class Modal extends Component {
  app: App;
  contentEl: HTMLElement;
  modalEl: HTMLElement;
  titleEl: HTMLElement;

  open(): void;
  close(): void;
  setTitle(title: string): this;
  setContent(content: string | DocumentFragment): this;
}

abstract class SuggestModal<T> extends Modal {
  abstract getSuggestions(query: string): T[];
  abstract renderSuggestion(value: T, el: HTMLElement): void;
  abstract onChooseSuggestion(item: T, evt: MouseEvent | KeyboardEvent): void;
}

abstract class FuzzySuggestModal<T> extends SuggestModal<FuzzyMatch<T>> {
  abstract getItems(): T[];
  abstract getItemText(item: T): string;
  abstract onChooseItem(item: T, evt: MouseEvent | KeyboardEvent): void;
}
```

### Setting

UI component for creating settings.

```typescript
class Setting {
  constructor(containerEl: HTMLElement);

  setName(name: string | DocumentFragment): this;
  setDesc(desc: string | DocumentFragment): this;
  setHeading(): this;
  setClass(cls: string): this;
  setTooltip(tooltip: string, options?: TooltipOptions): this;

  addText(cb: (component: TextComponent) => any): this;
  addTextArea(cb: (component: TextAreaComponent) => any): this;
  addToggle(cb: (component: ToggleComponent) => any): this;
  addDropdown(cb: (component: DropdownComponent) => any): this;
  addSlider(cb: (component: SliderComponent) => any): this;
  addButton(cb: (component: ButtonComponent) => any): this;
  addExtraButton(cb: (component: ExtraButtonComponent) => any): this;
  addSearch(cb: (component: SearchComponent) => any): this;
  addColorPicker(cb: (component: ColorComponent) => any): this;
  addProgressBar(cb: (component: ProgressBarComponent) => any): this;
  addMomentFormat(cb: (component: MomentFormatComponent) => any): this;
}
```

### FileManager

```typescript
class FileManager {
  processFrontMatter(file: TFile, fn: (frontmatter: any) => void, options?: DataWriteOptions): Promise<void>;
  getNewFileParent(sourcePath: string): TFolder;
  generateMarkdownLink(file: TFile, sourcePath: string, subpath?: string, alias?: string): string;
}
```

### MetadataCache

```typescript
class MetadataCache extends Events {
  getFileCache(file: TFile): CachedMetadata | null;
  getFirstLinkpathDest(linkpath: string, sourcePath: string): TFile | null;
  resolvedLinks: Record<string, Record<string, number>>;

  on(name: 'changed', callback: (file: TFile, data: string, cache: CachedMetadata) => any): EventRef;
  on(name: 'resolve', callback: (file: TFile) => any): EventRef;
  on(name: 'resolved', callback: () => any): EventRef;
}
```

### Menu

```typescript
class Menu extends Component {
  addItem(cb: (item: MenuItem) => any): this;
  addSeparator(): this;
  showAtMouseEvent(event: MouseEvent): this;
  showAtPosition(position: { x: number; y: number }, doc?: Document): this;
}

class MenuItem {
  setTitle(title: string | DocumentFragment): this;
  setIcon(icon: string | null): this;
  setChecked(checked: boolean | null): this;
  setDisabled(disabled: boolean): this;
  setIsLabel(isLabel: boolean): this;
  onClick(callback: (evt: MouseEvent | KeyboardEvent) => any): this;
  setSection(section: string): this;
  setSubmenu(): Menu;
}
```

## Utility Functions

```typescript
// Normalize file paths
function normalizePath(path: string): string;

// Add custom icon
function addIcon(iconId: string, svgContent: string): void;

// Set icon on element
function setIcon(parent: HTMLElement, iconId: string): void;

// HTTP requests (works on all platforms including mobile)
function requestUrl(request: RequestUrlParam | string): Promise<RequestUrlResponse>;

// Render markdown to HTML
namespace MarkdownRenderer {
  function render(app: App, markdown: string, el: HTMLElement, sourcePath: string, component: Component): Promise<void>;
}

// Fuzzy search
function prepareFuzzySearch(query: string): (text: string) => SearchResult | null;

// Moment.js (bundled with Obsidian)
import { moment } from 'obsidian';

// Platform detection
import { Platform } from 'obsidian';
Platform.isDesktop: boolean;
Platform.isMobile: boolean;
Platform.isMacOS: boolean;
Platform.isWin: boolean;
Platform.isLinux: boolean;
```

## File Types

```typescript
abstract class TAbstractFile {
  vault: Vault;
  path: string;
  name: string;
  parent: TFolder | null;
}

class TFile extends TAbstractFile {
  stat: FileStats;
  basename: string;
  extension: string;
}

class TFolder extends TAbstractFile {
  children: TAbstractFile[];
  isRoot(): boolean;
}
```

## Command Interface

```typescript
interface Command {
  id: string;
  name: string;
  icon?: string;
  hotkeys?: Hotkey[];

  callback?: () => any;
  checkCallback?: (checking: boolean) => boolean | void;
  editorCallback?: (editor: Editor, ctx: MarkdownView | MarkdownFileInfo) => any;
  editorCheckCallback?: (checking: boolean, editor: Editor, ctx: MarkdownView | MarkdownFileInfo) => boolean | void;
}
```

## CSS Variables (Key Subset)

```css
/* Text */
--text-normal
--text-muted
--text-faint
--text-accent
--text-on-accent
--text-error

/* Backgrounds */
--background-primary
--background-secondary
--background-modifier-border
--background-modifier-error
--background-modifier-success

/* Interactive */
--interactive-normal
--interactive-hover
--interactive-accent
--interactive-accent-hover

/* Fonts */
--font-text
--font-monospace
--font-interface

/* Sizing */
--icon-size
--icon-size-s
--icon-size-m
--icon-size-l
```
