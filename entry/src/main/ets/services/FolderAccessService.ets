import { common } from '@kit.AbilityKit';
import { fileIo, fileShare, fileUri } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';

export interface SavedFolder {
  uri: string;
  name: string;
}

export class FolderAccessService {
  static async persist(context: common.UIAbilityContext, folder: SavedFolder): Promise<boolean> {
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) return false;
    try {
      const policy: fileShare.PolicyInfo = {
        uri: folder.uri,
        operationMode: fileShare.OperationMode.READ_MODE
      };
      await fileShare.persistPermission([policy]);
      const store = await preferences.getPreferences(context, { name: 'lyricflow_folder' });
      store.putSync('uri', folder.uri);
      store.putSync('name', folder.name);
      await store.flush();
      return true;
    } catch (_error) {
      return false;
    }
  }

  static async restore(context: common.UIAbilityContext): Promise<SavedFolder | undefined> {
    if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) return undefined;
    try {
      const store = await preferences.getPreferences(context, { name: 'lyricflow_folder' });
      const uri: string = store.getSync('uri', '') as string;
      const name: string = store.getSync('name', '') as string;
      if (uri.length === 0) return undefined;
      const policy: fileShare.PolicyInfo = {
        uri,
        operationMode: fileShare.OperationMode.READ_MODE
      };
      await fileShare.activatePermission([policy]);
      const path: string = new fileUri.FileUri(uri).path;
      const stat = await fileIo.stat(path);
      if (!stat.isDirectory()) return undefined;
      return { uri, name };
    } catch (_error) {
      return undefined;
    }
  }
}
