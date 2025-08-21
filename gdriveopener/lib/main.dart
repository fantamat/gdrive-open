import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:installed_apps/installed_apps.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MainApp());
}


class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DriveOpenerHome(),
    );

  }
}



class DriveDirectory {
  final String id;
  final String display;
  DriveDirectory({required this.id, required this.display});
}

class DriveOpenerHome extends StatefulWidget {
  @override
  State<DriveOpenerHome> createState() => _DriveOpenerHomeState();
}

class _DriveOpenerHomeState extends State<DriveOpenerHome> {
  final TextEditingController _controller = TextEditingController();
  final List<DriveDirectory> _directories = [];

  static const String _prefsKey = 'drive_directories';
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadDirectories();
  }

  Future<void> _loadDirectories() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? saved = prefs.getStringList(_prefsKey);
    if (saved != null) {
      setState(() {
        _directories.clear();
        _directories.addAll(saved.map((e) {
          final parts = e.split('|');
          return DriveDirectory(id: parts[0], display: parts.length > 1 ? parts[1] : parts[0]);
        }));
      });
    }
  }

  Future<void> _saveDirectories() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> toSave = _directories.map((d) => '${d.id}|${d.display}').toList();
    await prefs.setStringList(_prefsKey, toSave);
  }

  String? _extractDriveId(String input) {
    // Try to extract ID from link or return input if it looks like an ID
    final uri = Uri.tryParse(input);
    if (uri != null && uri.host.contains('drive.google.com')) {
      final regExp = RegExp(r'/folders?/([a-zA-Z0-9_-]+)');
      final match = regExp.firstMatch(uri.path);
      if (match != null) {
        return match.group(1);
      }
    }
    // fallback: if input is likely an ID
    if (input.length >= 10 && !input.contains(' ')) {
      return input;
    }
    return null;
  }

  Future<void> _addDirectory() async {
    final input = _controller.text.trim();
    final id = _extractDriveId(input);
    if (id != null) {
      setState(() {
        _directories.add(DriveDirectory(id: id, display: input));
        _controller.clear();
      });
      await _saveDirectories();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid Google Drive folder link or ID.')),
      );
    }
  }

  Future<bool> _isAppInstalled(String packageName) async {
    try {
      return await InstalledApps.isAppInstalled(packageName) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _processDirectory(DriveDirectory dir) async {
    setState(() { _isProcessing = true; });
    try {
      await signInWithGoogle();
      final googleUser = await GoogleSignIn(
        scopes: [drive.DriveApi.driveScope],
      ).signIn();
      final authHeaders = await googleUser?.authHeaders;
      if (authHeaders == null) throw Exception('Missing Google auth headers');
      final client = GoogleAuthClient(authHeaders);
      final driveApi = drive.DriveApi(client);
      // Recursively fetch all files in the folder and its subfolders
      Future<List<drive.File>> fetchFilesRecursively(String folderId) async {
        List<drive.File> allFiles = [];
        // Get files and folders in the current folder
        final fileList = await driveApi.files.list(
          q: "'$folderId' in parents and trashed = false",
          $fields: 'files(id,name,mimeType,webViewLink)',
        );
        if (fileList.files == null) return allFiles;
        for (final f in fileList.files!) {
          if (f.mimeType == 'application/vnd.google-apps.folder') {
        // Recurse into subfolder
        allFiles.addAll(await fetchFilesRecursively(f.id!));
          } else {
        allFiles.add(f);
          }
        }
        return allFiles;
      }

      final files = await fetchFilesRecursively(dir.id);
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No files found in this folder.')),
        );
      } else {
        for (final f in files) {
          final mime = f.mimeType ?? '';
            if (mime == 'application/vnd.google-apps.spreadsheet' ||
              mime == 'application/vnd.google-apps.document') {
            if (f.webViewLink != null) {
              await launchUrl(Uri.parse(f.webViewLink!), mode: LaunchMode.externalApplication);
              await Future.delayed(const Duration(seconds: 3));
              
            }
          }
        }

        // showDialog(
        //   context: context,
        //   builder: (context) => AlertDialog(
        //     title: const Text('Files in Folder'),
        //     content: SizedBox(
        //       width: double.maxFinite,
        //       child: ListView(
        //         shrinkWrap: true,
        //         children: fileList.files!.map((f) => ListTile(
        //           title: Text(f.name ?? ''),
        //           subtitle: Text(f.mimeType ?? ''),
        //           onTap: () async {
        //             if (f.webViewLink != null) {
        //               await launchUrl(Uri.parse(f.webViewLink!), mode: LaunchMode.externalApplication);
        //             }
        //           },
        //         )).toList(),
        //       ),
        //     ),
        //     actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        //   ),
        // );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    }
    setState(() { _isProcessing = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Google Drive Opener')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Google Drive Folder ID or Link',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addDirectory,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: _directories.length,
                itemBuilder: (context, index) {
                  final dir = _directories[index];
                  return Card(
                    child: ListTile(
                      title: Text(dir.display),
                      subtitle: Text('ID: ${dir.id}'),
                      trailing: ElevatedButton(
                        onPressed: _isProcessing ? null : () => _processDirectory(dir),
                        child: const Text('Open Files'),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_isProcessing) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Processing files...'),
            ]
          ],
        ),
      ),
    );
  }
}

// Helper class for authenticated requests
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  GoogleAuthClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

final googleSignIn = GoogleSignIn(
  scopes: [drive.DriveApi.driveScope],
);

Future<UserCredential> signInWithGoogle() async {
  final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
  final GoogleSignInAuthentication? googleAuth = await googleUser?.authentication;

  final credential = GoogleAuthProvider.credential(
    accessToken: googleAuth?.accessToken,
    idToken: googleAuth?.idToken,
  );

  return await FirebaseAuth.instance.signInWithCredential(credential);
}
