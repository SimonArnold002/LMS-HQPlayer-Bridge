VERSION = 4.0.0

TARGET = hqp6-control
TEMPLATE = app
QT -= gui
QT += core network
CONFIG += c++20
CONFIG += console
CONFIG += embed_manifest_exe

win32 {
	LIBS += user32.lib

	INCLUDEPATH += C:/common/include/botan-3

	CONFIG(release, debug|release) {
		LIBS += C:/common/lib/botan-3.lib
	} else {
		LIBS += C:/common/lib/botan-3d.lib
	}
}

unix:!macx {
	CONFIG += link_pkgconfig
	PKGCONFIG += botan-3
}

macx {
	INCLUDEPATH += /usr/local/include/botan-3
	LIBS += -L/usr/local/lib -lbotan-3
	QMAKE_MACOSX_DEPLOYMENT_TARGET = 14.0
}

HEADERS += \
	ControlApplication.hpp \
	ControlInterface.hpp
SOURCES += \
	ControlApplication.cpp \
	ControlInterface.cpp \
	Main.cpp

