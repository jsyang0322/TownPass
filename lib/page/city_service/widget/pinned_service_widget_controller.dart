import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';

class PinnedServiceWidgetController extends GetxController {
  final RxList<MyServiceItemId> _pinnedList = RxList(
    [
      // 這份清單只存在記憶體，App 重開就回到預設；放在預設清單，demo 時不用每次手動加入
      MyServiceItemId.voiceAgent,
      MyServiceItemId.locationSearch,
      MyServiceItemId.districtOffice,
      MyServiceItemId.dashboard,
    ],
  );

  RxList<MyServiceItemId> get pinnedList => _pinnedList;

  bool remove(MyServiceItemId itemId) {
    return _pinnedList.remove(itemId);
  }

  bool replaceWith(List<MyServiceItemId> list) {
    if (list.isNotEmpty) {
      _pinnedList.value = list;
      return true;
    }
    return false;
  }

  bool push(MyServiceItemId itemId) {
    if (_pinnedList.length < 12) {
      _pinnedList.add(itemId);
      return true;
    }
    return false;
  }
}
