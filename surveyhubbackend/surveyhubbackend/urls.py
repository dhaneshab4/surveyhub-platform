"""
URL configuration for surveyhubbackend project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/5.1/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.contrib import admin
from django.urls import path, include
from rest_framework_simplejwt.views import TokenObtainPairView, TokenRefreshView

from surveys.observability import healthz, metrics_view, readyz

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('surveys.urls')),
    path('api/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('api/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),

    # Operational endpoints. Deliberately unauthenticated and outside /api/ so that
    # probes and the Prometheus scraper never need a credential. /metrics must not be
    # publicly routable in production — see PLATFORM.md.
    path('healthz', healthz, name='healthz'),
    path('readyz', readyz, name='readyz'),
    path('metrics', metrics_view, name='metrics'),
]