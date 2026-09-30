## Purpose

從 Safari 的 WebKit 網路快取取出使用者已載入的 PDF：只讀檔案，不送任何請求，也不需要人按任何按鈕。取出必須明確指定要哪一份；對應不到或對應到多份時停止並列出候選，不猜。

## ADDED Requirements

### Requirement: The command reads only the WebKit network cache and sends no request

`pdf-cache` SHALL obtain PDF bytes only by reading files under Safari's WebKit network cache, or, when `--source webkit-pdfs` is given, files under Safari's `WebKitPDFs-*` temporary folders. It SHALL NOT issue any network request, SHALL NOT navigate, reload, or evaluate JavaScript in any tab, and SHALL NOT press or otherwise drive any Safari control. It SHALL NOT require Safari to be running, except that `get` with a tab-targeting flag reads the target tab's URL through the existing target resolution.

#### Scenario: no request is made

- **WHEN** `safari-browser pdf-cache get out.pdf --key 0123abcd` runs
- **THEN** the command reads the cache and writes `out.pdf` without contacting any host and without running any script in Safari

#### Scenario: Safari not running

- **WHEN** Safari is not running and `pdf-cache list` runs
- **THEN** the command lists the cache contents without launching Safari

### Requirement: Retrieval requires an explicit selection

`pdf-cache get` SHALL act only on a selection the caller states. The selection forms are a closed list of three; no other input SHALL be treated as a selection, and none SHALL be inferred from similarity to these:

1. a tab-targeting flag: `--url`, `--url-exact`, `--url-endswith`, `--url-regex`, `--window` (with or without `--tab-in-window`), `--document`, or `--tab`;
2. `--key <prefix>`;
3. `--source webkit-pdfs --file <name>`.

When no selection is given, the command SHALL fail before reading the cache and before creating any file. When more than one selection form is given, the command SHALL fail with a usage error. `--profile` and `--first-match` alone are not selections. The command SHALL NOT choose the newest, the largest, or the only PDF on the caller's behalf.

#### Scenario: nothing selected

- **WHEN** `safari-browser pdf-cache get out.pdf` runs with no selection flag
- **THEN** the command fails naming the three selection forms
- **AND** `out.pdf` does not exist afterwards and the cache was not read

#### Scenario: a profile alone is not a selection

- **WHEN** `safari-browser pdf-cache get out.pdf --profile Work` runs
- **THEN** the command fails as if no selection had been given

#### Scenario: two selection forms

- **WHEN** `safari-browser pdf-cache get out.pdf --url plaud --key 0123abcd` runs
- **THEN** the command fails with a usage error before any read

#### Scenario: only one PDF is cached

- **WHEN** the cache holds exactly one PDF and `pdf-cache get out.pdf` runs with no selection
- **THEN** the command still fails; it does not select that PDF

### Requirement: A tab selection maps to a record by exact URL

For a tab-targeting selection, the command SHALL read the target tab's URL through the existing target resolution (which fails closed on an ambiguous match), remove the URL fragment, and compare the result to each cached record's request URL by bytes (UTF-8), with no normalization of scheme, host, path, port, or query and no Unicode canonical equivalence: text that differs only in how a character is encoded does not match. When zero records match, the command SHALL fail and SHALL say that the tab's URL has no cached PDF, with the URL shown as required by "URLs are shown without query or fragment". When more than one record matches, the command SHALL fail and SHALL list every matching candidate (key prefix, partition, size, time) and SHALL NOT choose one. `--key` SHALL match the record file name by case-insensitive prefix of at least 8 hexadecimal characters and SHALL fail on zero or more than one match.

#### Scenario: one record matches

- **WHEN** the target tab's URL is `https://example.org/a.pdf#page=3` and exactly one cached PDF record has request URL `https://example.org/a.pdf`
- **THEN** that record is selected

#### Scenario: the query differs

- **WHEN** the target tab's URL is `https://example.org/a.pdf?x=1` and the only cached record has request URL `https://example.org/a.pdf`
- **THEN** the command fails with no match; it does not fall back to the record without the query

#### Scenario: the same URL in two partitions

- **WHEN** two cached PDF records in different partitions have the same request URL as the target tab
- **THEN** the command fails and lists both candidates
- **AND** neither is written

#### Scenario: key prefix too short

- **WHEN** `--key 0123` is given
- **THEN** the command fails with a usage error stating the 8-character minimum

### Requirement: Retrieval writes a verified copy atomically

`pdf-cache get` SHALL open the source read-only and SHALL NOT modify it. It SHALL require the source's first five bytes to be `%PDF-`. It SHALL write the bytes to a temporary file created exclusively, with mode `0600`, in the destination's directory; verify that CoreGraphics opens it as a PDF with at least one page and that every page's entry in the page tree can be read (content streams and images are not decoded, so a document whose page tree is intact but whose content is damaged passes); and then publish it by renaming it onto the destination path. The command SHALL NOT replace the file it is copying from: when the destination is that file, whether by the same path, a symbolic link, or a hard link (the same device and inode), it SHALL fail before writing. When the destination exists, the command SHALL fail unless `--force` is given. On any failure the command SHALL leave no file at the destination that it created and no temporary file; when a temporary file cannot be removed (a folder can allow creating a file and deny removing it), the error SHALL keep the original reason and SHALL say that the staged file was left and where. The destination's directory SHALL already exist. It SHALL be opened once, and the temporary file, the verification, the publication, and the cleanup SHALL all refer to that opened folder and to the file that was written, not to paths resolved again; the verification SHALL read the file that was written, and the publication SHALL fail when the staging name no longer refers to it. (The command defends against mistakes and stale state, not against another process of the same user rewriting the destination folder while it runs.) On success it SHALL print one line, or with `--json` one object, giving the destination path, the size, the page count, and where the PDF came from (the key and the URL shown as required by "URLs are shown without query or fragment", or the folder and file name).

#### Scenario: verified copy published

- **WHEN** the selected record's body is a readable PDF and the destination does not exist
- **THEN** the destination exists with mode `0600`, its bytes equal the body, and no temporary file remains

#### Scenario: not a PDF

- **WHEN** the selected record's body does not start with `%PDF-`
- **THEN** the command fails and creates nothing

#### Scenario: unreadable PDF

- **WHEN** the body starts with `%PDF-` but CoreGraphics cannot read a page from it
- **THEN** the command fails, the destination is unchanged, and no temporary file remains

#### Scenario: the destination is the source

- **WHEN** `--force` is given and the destination is the cached file being copied, or a symbolic link or hard link to it
- **THEN** the command fails and the cached file keeps its content, inode, and permissions

#### Scenario: destination exists

- **WHEN** the destination already exists and `--force` is not given
- **THEN** the command fails and the existing file is unchanged

#### Scenario: a destination that appears while verifying

- **WHEN** without `--force`, the destination is created by another process after the early existence check and before publication
- **THEN** the command fails with the destination-exists error, the other process's file is unchanged, and no temporary file remains

#### Scenario: the staged copy is replaced

- **WHEN** the staging name is pointed at another file after verification and before publication
- **THEN** nothing is published and neither the destination nor a temporary file remains

#### Scenario: a symbolic link as the destination

- **WHEN** the destination is a symbolic link (to a file, to a folder, or dangling) and `--force` is given
- **THEN** the symbolic link itself is replaced and what it pointed at is unchanged
- **AND** without `--force` the destination is reported as existing

#### Scenario: force replaces

- **WHEN** the destination exists and `--force` is given and the copy verifies
- **THEN** the destination is replaced by the verified copy in one rename

### Requirement: The listing shows PDFs only

`pdf-cache list` SHALL list only records whose body is a regular file that starts with `%PDF-`, and SHALL decide that by reading no more than the first five bytes of each body. A body file or record file that is not a regular file (a folder, or a symbolic link) SHALL NOT be used: a body is skipped without failing the scan, and a record is unreadable. A record whose key carries a byte range holds part of a resource, not a document: it SHALL NOT be listed or selected, `list` SHALL note their number on stderr, and `get --key` naming one SHALL say that it holds only a byte range. Each row SHALL show the first 12 characters of the record key, the partition (or `-` when empty), the request URL as required by "URLs are shown without query or fragment", the body size, and the record's modification time in local time. Rows SHALL be ordered newest first and limited by `--limit` (default 50, a positive integer). `--json` SHALL print an array whose objects carry the full `key`, `partition`, `url`, `has_query`, `size`, and `modified` (ISO 8601); with `--source webkit-pdfs` the objects carry `file`, `folder`, `size`, and `modified`. Explanatory text SHALL go to stderr and rows to stdout. When no PDF is cached, the command SHALL exit successfully with an explanatory note on stderr and, with `--json`, `[]` on stdout.

#### Scenario: default limit

- **WHEN** the cache holds 80 PDFs and `pdf-cache list` runs
- **THEN** 50 rows are printed, newest first

#### Scenario: no PDFs

- **WHEN** the cache holds no PDF
- **THEN** stdout is empty (or `[]` with `--json`), stderr says none were found, and the exit status is 0

#### Scenario: non-PDF bodies are not read further

- **WHEN** the cache holds thousands of non-PDF bodies
- **THEN** the command reads at most five bytes of each and lists none of them

### Requirement: URLs are shown without query or fragment

The query and fragment SHALL be located among Unicode scalars, so that a combining mark after `?` or `#` cannot hide them. Every URL the command itself prints — in list rows, JSON, `get` output, and its own error messages — SHALL be shown with its query and fragment removed. Errors raised by the shared tab resolution when a tab flag matches no tab or several tabs (`documentNotFound`, `ambiguousWindowMatch`) list the URLs of open tabs as they do for every command; they are not produced by this command and are outside this requirement. Matching SHALL use the complete URL as specified in "A tab selection maps to a record by exact URL"; only display is reduced. The JSON field `has_query` SHALL say whether a query was removed.

#### Scenario: a signed URL is listed

- **WHEN** a cached record's request URL is `https://cdn.example.org/f.pdf?X-Signature=abc`
- **THEN** the row and the JSON show `https://cdn.example.org/f.pdf` and `has_query` is true
- **AND** the string `X-Signature` appears nowhere in the output

#### Scenario: an error names a URL

- **WHEN** a tab selection has no match and the tab's URL is `https://cdn.example.org/f.pdf?X-Signature=abc`
- **THEN** the error names `https://cdn.example.org/f.pdf` and does not contain the query

### Requirement: The cache layout is validated and unsupported layouts fail closed

The command SHALL accept only the cache version directory `Version 17`. The failure classes below are a closed list of five; each SHALL fail with a message naming what was seen, and none SHALL be reinterpreted as a missing PDF:

1. the WebKit cache folder does not exist;
2. no `Version 17` directory exists (the message lists the `Version *` directories that do);
3. a record selected for use does not begin with `uint32 version 17`, then the strings partition, `Resource`, and identifier, then the range (`0xFFFFFFFF` for none, otherwise a string) and a 20-byte hash whose hexadecimal form equals the record's file name (case-insensitive), each string being `uint32 length`, one byte `is8Bit`, and the characters (UTF-16LE when `is8Bit` is 0), with each string at most 65536 characters, or it is truncated;
4. PDF bodies exist and none of their records parse under class 3;
5. the `Version 17` folder has no `Records` folder (the message lists what it does hold).

A record that fails class 3 while others parse SHALL be left out of `list` output and counted in a stderr note; `get --key` on it SHALL fail.

#### Scenario: another version directory

- **WHEN** the cache folder contains `Version 18` and no `Version 17`
- **THEN** the command fails naming `Version 18`

#### Scenario: drifted record layout

- **WHEN** every PDF body's record fails the leading-field check
- **THEN** the command fails as an unsupported layout rather than reporting that there are no PDFs

#### Scenario: no Records folder

- **WHEN** the `Version 17` folder holds no `Records` folder
- **THEN** the command fails as an unsupported layout and lists what the folder does hold
- **AND** it does not report that no PDF is cached

#### Scenario: a hash that is not the file name

- **WHEN** a record's bytes after the range do not equal its own file name
- **THEN** the record is treated as unreadable under class 3 and is not trusted

#### Scenario: a partial body

- **WHEN** a record whose key carries a byte range has a body that starts with `%PDF-`
- **THEN** it is not listed and not selectable, and `list` notes on stderr how many such bodies it left out
- **AND** when it is the only PDF body in the cache, the listing is empty rather than a layout error

#### Scenario: one unreadable record

- **WHEN** one of three PDF records fails the leading-field check
- **THEN** `list` prints the other two and notes on stderr that one record was not readable

### Requirement: The WebKitPDFs source is opt-in

`--source webkit-pdfs` SHALL switch `list` and `get` to the PDF files directly inside `WebKitPDFs-*` folders under `~/Library/Containers/com.apple.Safari/Data/tmp/`, identified by name and by the folder that holds them. The default source SHALL be the network cache. The command SHALL NOT create these folders or files, SHALL NOT press "Open with Preview" or any other control to make them appear, and SHALL NOT fall back from one source to the other. `get --source webkit-pdfs` SHALL require `--file <name>`; a name present in more than one folder SHALL fail and list the folders.

#### Scenario: the source is not switched automatically

- **WHEN** a tab selection finds no cached record and a `WebKitPDFs-*` folder holds a PDF of the same name
- **THEN** the command fails with no match and does not read the folder

#### Scenario: same name in two folders

- **WHEN** `--source webkit-pdfs --file a.pdf` finds `a.pdf` in two folders
- **THEN** the command fails and lists both folders

### Requirement: Access failures keep their cause

Reading the cache folder SHALL preserve the failing call's errno, for the open and for every lookup inside it; a folder that can be listed but not searched is a permission failure and never an empty listing. `EACCES` and `EPERM` SHALL be reported as a Full Disk Access requirement with the guidance the other local-data commands give for the binary's signing state; other errors SHALL be reported with their own errno text and SHALL NOT be reported as a permission problem or as a missing PDF.

#### Scenario: no Full Disk Access

- **WHEN** opening the cache folder fails with `EPERM`
- **THEN** the command fails with the Full Disk Access guidance for the current code-signing state
