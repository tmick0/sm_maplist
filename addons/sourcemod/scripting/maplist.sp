#include <sourcemod>
#include <adt_array>
#include <autoexecconfig>

#pragma newdecls required

public Plugin myinfo =
{
    name = "Map list generator",
    author = "tmick0",
    description = "Generates a map list",
    version = "0.1",
    url = "github.com/tmick0/sm_maplist"
};

#define MAP_DIRECTORY "maps/"
#define MAP_SUFFIX ".bsp"

#define CVAR_FILTERFILEPATH "sm_maplist_filterfile"
#define CVAR_FILTERRELATIVE "sm_maplist_filterrelative"
#define CVAR_DEBUG "sm_maplist_debug"

#define CMD_WRITEMAPLIST "sm_writemaplist"

#define MAXDEPTH 5
#define ERROR_STRING_LEN 32
#define CHAT_BUFFER_LEN 128

#define ERR_WRITE_FILE -1
#define ERR_LOAD_FILTER -2
#define ERR_FIND_MAPS -3

ConVar CvarFilterFilePath;
ConVar CvarFilterRelative;
ConVar CvarDebug;

public void OnPluginStart() {
    RegAdminCmd(CMD_WRITEMAPLIST, CmdWriteMapList, ADMFLAG_GENERIC);

    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_maplist");
    CvarFilterFilePath = AutoExecConfig_CreateConVar(CVAR_FILTERFILEPATH, "", "path to list of maps to exclude; empty string disables the filter");
    CvarFilterRelative = AutoExecConfig_CreateConVar(CVAR_FILTERRELATIVE, "1", "if 0, filter file contains full paths relative to the /map directory (e.g., workshop/1234/de_test); if 1, filter contains names only and does not care about which directory a map is in e.g. (de_test)");
    CvarDebug = AutoExecConfig_CreateConVar(CVAR_DEBUG, "0", "set to 1 to enable debug output");
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();
}

public Action CmdWriteMapList(int client, int argc) {
    if (argc != 1) {
        ReplyToCommand(client, "Usage: sm_writemaplist <output>");
        return Plugin_Handled;
    }

    char output[PLATFORM_MAX_PATH];
    GetCmdArg(1, output, sizeof(output));

    int count = GenerateMapList(output);

    char buf[CHAT_BUFFER_LEN];
    if (count < 0) {
        char err[ERROR_STRING_LEN];
        ErrorString(count, err, ERROR_STRING_LEN);
        LogMessage("error generating maplist requested by %L: %s (%d)", client, err, count);
        Format(buf, CHAT_BUFFER_LEN, "[maplist] error generating maplist: %s (%d)", err, count);
    }
    else {
        LogMessage("new maplist generated by %L with %d entries", client, count);
        Format(buf, CHAT_BUFFER_LEN, "[maplist] new maplist generated with %d entries", count);
    }
    ReplyToCommand(client, buf);

    return Plugin_Handled;
}

int GenerateMapList(const char[] output) {
    int verbose = GetConVarInt(CvarDebug);

    char FilterFilePath[PLATFORM_MAX_PATH];
    GetConVarString(CvarFilterFilePath, FilterFilePath, PLATFORM_MAX_PATH);

    int relative = GetConVarInt(CvarFilterRelative);

    ArrayList filter = new ArrayList(PLATFORM_MAX_PATH);
    int filterc = LoadFilter(FilterFilePath, filter);
    if (filterc < 0) {
        return filterc;
    }

    ArrayList maps = new ArrayList(PLATFORM_MAX_PATH);
    int count = FindMaps(MAP_DIRECTORY, 0, filter, maps, relative, verbose);
    if (count < 0) {
        return count;
    }

    SortADTArrayCustom(maps, MapComparator);

    Handle fh = OpenFile(output, "w");
    if (fh == INVALID_HANDLE) {
        return ERR_WRITE_FILE;
    }

    int prefixlen = strlen(MAP_DIRECTORY);
    for (int i = 0; i < count; ++i) {
        char entry[PLATFORM_MAX_PATH];
        maps.GetString(i, entry, PLATFORM_MAX_PATH);
        WriteFileLine(fh, "%s", entry[prefixlen]);
    }

    CloseHandle(fh);

    return count;
}

int LoadFilter(const char[] path, ArrayList output) {
    if (strlen(path) == 0) {
        LogMessage("no filter file specified");
        return 0;
    }

    int count = 0;
    Handle fh = OpenFile(path, "r");
    if (fh == INVALID_HANDLE) {
        return ERR_LOAD_FILTER;
    }

    char line[PLATFORM_MAX_PATH];
    while (ReadFileLine(fh, line, PLATFORM_MAX_PATH)) {
        TrimString(line);
        if (strlen(line) > 0 && line[0] != '#') {
            output.PushString(line);
            ++count;
        }
    }

    CloseHandle(fh);

    LogMessage("loaded %d entries from filter file <%s>", count, path);
    return count;
}

int FindMaps(char[] directory, int depth, ArrayList filter, ArrayList output, int relative, int verbose) {
    if (depth >= MAXDEPTH) {
        return 0;
    }

    if (verbose) {
        LogMessage("entering directory: <%s>", directory);
    }

    // remove trailing slash
    int dlen = strlen(directory);
    if (directory[dlen - 1] == '/') {
        directory[dlen - 1] = '\0';
    }

    int count = 0;

    Handle dh = OpenDirectory(directory);
    if (dh == INVALID_HANDLE) {
        return ERR_FIND_MAPS;
    }

    char entry[PLATFORM_MAX_PATH];
    FileType type;
    while (ReadDirEntry(dh, entry, PLATFORM_MAX_PATH, type)) {
        if (type == FileType_Directory) {
            if (strcmp(entry, ".") && strcmp(entry, "..")) {
                char path[PLATFORM_MAX_PATH];
                Format(path, PLATFORM_MAX_PATH, "%s/%s", directory, entry);

                // recurse
                int res = FindMaps(path, depth + 1, filter, output, relative, verbose);
                if (res < 0) {
                    CloseHandle(dh);
                    return res;
                }

                count += res;
            }
        }
        else if (type == FileType_File) {
            // check if it is a map
            int baselen = strlen(entry) - strlen(MAP_SUFFIX);
            if (StrContains(entry, MAP_SUFFIX) == baselen) {
                if (verbose) {
                    LogMessage("found a map: <%s>", entry);
                }

                char basename[PLATFORM_MAX_PATH];
                strcopy(basename, baselen + 1 < PLATFORM_MAX_PATH ? baselen + 1 : PLATFORM_MAX_PATH, entry);

                char path[PLATFORM_MAX_PATH];
                Format(path, PLATFORM_MAX_PATH, "%s/%s", directory, basename);

                if (!CheckFilter(path, filter, relative, verbose)) {
                    output.PushString(path);
                    ++count;
                }
            }
        }
    }

    CloseHandle(dh);
    return count;
}

bool CheckFilter(const char[] path, ArrayList filter, int relative, int verbose) {
    char compare_name[PLATFORM_MAX_PATH];
    if (relative) {
        int last_sep = FindCharInString(path, '/', true);
        strcopy(compare_name, PLATFORM_MAX_PATH, path[last_sep + 1]);
    }
    else {
        strcopy(compare_name, PLATFORM_MAX_PATH, path[strlen(MAP_DIRECTORY)]);
    }
    bool result = filter.FindString(compare_name) != -1;
    if (verbose) {
        LogMessage("checking filter for <%s>", compare_name);
        LogMessage(" is in filter? %s", result ? "yes" : "no");
    }
    return result;
}

void ErrorString(int code, char[] buffer, int buffersz) {
    if (code == ERR_WRITE_FILE) {
        strcopy(buffer, buffersz, "failed to write output file");
    }
    else if (code == ERR_LOAD_FILTER) {
        strcopy(buffer, buffersz, "failed to load filters");
    }
    else if (code == ERR_FIND_MAPS) {
        strcopy(buffer, buffersz, "failed to iterate map directory");
    }
    else {
        strcopy(buffer, buffersz, "unknown");
    }
}

int MapComparator(int i0, int i1, Handle arr, Handle aux) {
    char v0[PLATFORM_MAX_PATH];
    char v1[PLATFORM_MAX_PATH];

    if (GetArrayString(arr, i0, v0, PLATFORM_MAX_PATH) < 0) {
        return 0;
    }
    if (GetArrayString(arr, i1, v1, PLATFORM_MAX_PATH) < 0) {
        return 0;
    }

    int t0 = FindCharInString(v0, '/', true);
    int t1 = FindCharInString(v1, '/', true);

    return strcmp(v0[t0 + 1], v1[t1 + 1], false);
}
