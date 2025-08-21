import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:googledrivehandler/googledrivehandler.dart';
import 'package:installed_apps/installed_apps.dart';
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

  Future<void> _openFile(String url, String packageName) async {
    final installed = await _isAppInstalled(packageName);
    if (installed) {
      await InstalledApps.startApp(packageName);
      // Optionally, you can use url_launcher to open the file URL if needed
    }
  }

  Future<void> _processDirectory(DriveDirectory dir) async {
    setState(() { _isProcessing = true; });
    try {
      // The package only supports picking a file interactively, not listing all files programmatically.
      // So we call getFileFromGoogleDrive and let the user pick files one by one.
      // Ensure user is signed in with Google before accessing Drive files
      await signInWithGoogle();
      while (true) {
        var file = await GoogleDriveHandler().getFileFromGoogleDrive(context: context);
        if (file == null) break;
        // file is a File instance, but we can't get mimeType directly. You may need to infer from extension.
        final path = file.path;
        if (path.endsWith('.gdoc')) {
          if (await _isAppInstalled('com.google.android.apps.docs.editors.docs')) {
            await _openFile(path, 'com.google.android.apps.docs.editors.docs');
            await Future.delayed(const Duration(seconds: 3));
          }
        } else if (path.endsWith('.gsheet')) {
          if (await _isAppInstalled('com.google.android.apps.docs.editors.sheets')) {
            await _openFile(path, 'com.google.android.apps.docs.editors.sheets');
            await Future.delayed(const Duration(seconds: 3));
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}')),
      );
    }
    setState(() { _isProcessing = false; });
  }

  Future<UserCredential> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
    final GoogleSignInAuthentication? googleAuth = await googleUser?.authentication;

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth?.accessToken,
      idToken: googleAuth?.idToken,
    );

    return await FirebaseAuth.instance.signInWithCredential(credential);
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
